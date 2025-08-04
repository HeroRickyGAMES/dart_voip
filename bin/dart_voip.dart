// meu_servidor_final.dart
import 'dart:io';
import 'dart:convert';

// Lista de usuários permitidos
final Map<String, String> allowedUsers = {
  '0': '1234',
  '1001': '1234',
  '1002': '1234'
};

// Guarda informações de cada usuário online, incluindo seu tipo de transporte
final Map<String, Map<String, dynamic>> onlineUsers = {};
// Guarda as chamadas ativas
final Map<String, Map<String, String>> activeCalls = {};

// Socket UDP principal para SIP tradicional
RawDatagramSocket? udpSocket;

void main() async {
  final udpHost = InternetAddress.anyIPv4;
  final udpPort = 5060;

  try {
    udpSocket = await RawDatagramSocket.bind(udpHost, udpPort);
    print('${DateTime.now()} ✅ Servidor SIP (UDP) escutando em ${udpSocket!.address.address}:$udpPort');

    // Listener para mensagens UDP
    udpSocket!.listen((RawSocketEvent event) {
      if (event == RawSocketEvent.read) {
        Datagram? datagram = udpSocket!.receive();
        if (datagram == null) return;

        // Se o pacote for pequeno e não for texto, assumimos que é áudio (RTP)
        if (datagram.data.length < 400 && (datagram.data[0] & 0xC0) == 0x80) {
          handleRtp(udpSocket!, datagram); // RTP só funciona com UDP socket
        } else {
          final message = utf8.decode(datagram.data, allowMalformed: true);
          final clientAddress = datagram.address;
          final clientPort = datagram.port;
          handleSipMessage(message, 'udp', udpSocket, clientAddress, clientPort, null);
        }
      }
    });
  } catch (e) {
    print('${DateTime.now()}❌ Erro ao iniciar o servidor UDP: $e');
  }

  // --- Início do Servidor WebSocket ---
  final wsHost = InternetAddress.anyIPv4;
  final wsPort = 5061; // Porta para WebSocket (ws://) - diferente da UDP

  try {
    HttpServer.bind(wsHost, wsPort).then((HttpServer server) {
      print('${DateTime.now()} ✅ Servidor SIP (WebSocket - WS) escutando em ${server.address.address}:$wsPort');

      server.listen((HttpRequest request) {
        if (WebSocketTransformer.isUpgradeRequest(request)) {
          WebSocketTransformer.upgrade(request).then((WebSocket webSocket) {
            final clientIp = request.connectionInfo?.remoteAddress.address ?? 'IP Desconhecido WS';
            final clientPort = request.connectionInfo?.remotePort ?? 0; // Porta do cliente WS (informativo)
            print('${DateTime.now()} 📞 Cliente WebSocket conectado de $clientIp:$clientPort');

            webSocket.listen(
                  (wsMessage) {
                if (wsMessage is String) {
                  print('${DateTime.now()} 📩 Mensagem SIP (WebSocket) de $clientIp: $wsMessage');
                  handleSipMessage(wsMessage, 'ws', null, InternetAddress(clientIp), clientPort, webSocket);
                }
              },
              onDone: () {
                print('${DateTime.now()} 💔 Cliente WebSocket desconectado: $clientIp:$clientPort');
                // Encontrar e remover usuário se estava registrado via WS
                String? userToRemove;
                onlineUsers.forEach((user, details) {
                  if (details['type'] == 'ws' && details['socket'] == webSocket) {
                    userToRemove = user;
                  }
                });
                if (userToRemove != null) {
                  onlineUsers.remove(userToRemove);
                  print("${DateTime.now()} 👤 Ramal '$userToRemove' (WS) desconectado.");
                }
              },
              onError: (error) {
                print('${DateTime.now()} ❌ Erro no WebSocket de $clientIp:$clientPort: $error');
              },
            );
          }).catchError((e) {
            print('${DateTime.now()} ❌ Erro no upgrade para WebSocket: $e');
          });
        } else {
          request.response.statusCode = HttpStatus.forbidden;
          request.response.write('Servidor SIP. Use uma conexão WebSocket para esta porta.');
          request.response.close();
        }
      });
    }).catchError((e) {
      print('${DateTime.now()}❌ Erro ao iniciar o servidor HTTP/WebSocket: $e');
    });
  } catch (e) {
    print('${DateTime.now()}❌ Erro geral ao iniciar o servidor WebSocket: $e');
  }
  // --- Fim do Servidor WebSocket ---
}

// Função unificada para tratar mensagens SIP de qualquer transporte
void handleSipMessage(String message, String transportType, RawDatagramSocket? udpOriginSocket, InternetAddress clientAddress, int clientPort, WebSocket? wsOriginSocket) {
  if (message.startsWith('REGISTER')) {
    handleRegister(message, transportType, udpOriginSocket, clientAddress, clientPort, wsOriginSocket);
  } else if (message.startsWith('INVITE')) {
    handleInvite(message, transportType, udpOriginSocket, clientAddress, clientPort, wsOriginSocket);
  } else if (message.startsWith('BYE')) {
    handleBye(message, transportType, udpOriginSocket, clientAddress, clientPort, wsOriginSocket);
  } else {
    // Para outras mensagens (ACK, respostas 180, 200 OK para INVITE, etc.)
    proxySipMessage(message, transportType, udpOriginSocket, clientAddress, clientPort, wsOriginSocket);
  }
}

void handleRegister(String message, String transportType, RawDatagramSocket? udpOriginSocket, InternetAddress clientAddress, int clientPort, WebSocket? wsOriginSocket) {
  final fromHeader = RegExp(r'From:.*<sip:([^@]+)@').firstMatch(message);
  if (fromHeader == null) return;
  final username = fromHeader.group(1);
  if (username == null) return;

  if (allowedUsers.containsKey(username)) {
    if (transportType == 'udp') {
      onlineUsers[username] = {
        'type': 'udp',
        'address': clientAddress,
        'port': clientPort,
      };
      print("${DateTime.now()}✅ Ramal '$username' (UDP) registrado/atualizado de ${clientAddress.address}:$clientPort");
    } else if (transportType == 'ws') {
      onlineUsers[username] = {
        'type': 'ws',
        'socket': wsOriginSocket,
        'remoteAddress': clientAddress.address // Para referência/log
      };
      print("${DateTime.now()}✅ Ramal '$username' (WS) registrado/atualizado de ${clientAddress.address}");
    }

    final viaLine = RegExp(r'^Via:\s*(.*)$', multiLine: true).firstMatch(message)?.group(1)?.trim();
    if (viaLine == null) return;

    // Para UDP, adicionamos received e rport. Para WS, o servidor WS já lida com o IP/porta.
    // A biblioteca cliente SIP sobre WS pode não esperar rport ou 'received' no Via da mesma forma.
    // Algumas implementações de cliente/servidor SIP sobre WS podem não precisar/querer essa modificação no Via.
    // Por simplicidade, vamos manter a lógica de 'received' e 'rport' principalmente para UDP.
    // Para WS, o cliente geralmente espera que a resposta volte pela mesma conexão WS.
    String correctedVia = viaLine;
    if (transportType == 'udp') {
      correctedVia = '$viaLine;received=${clientAddress.address};rport=$clientPort';
    }

    final fromHeaderLine = RegExp(r'^From:\s*(.*)$', multiLine: true).firstMatch(message)?.group(1)?.trim();
    final toHeaderLine = RegExp(r'^To:\s*(.*)$', multiLine: true).firstMatch(message)?.group(1)?.trim();
    final callIdHeader = RegExp(r'^Call-ID:\s*(.*)$', multiLine: true).firstMatch(message)?.group(1)?.trim();
    final cseqHeader = RegExp(r'^CSeq:\s*(.*)$', multiLine: true).firstMatch(message)?.group(1)?.trim();

    // O Contact para WS pode precisar ser tratado de forma diferente pelo cliente,
    // mas por agora, vamos usar o que o cliente enviar.
    final contactHeader = RegExp(r'^Contact:\s*(.*)$', multiLine: true).firstMatch(message)?.group(1)?.trim();

    final response = ['SIP/2.0 200 OK', 'Via: $correctedVia', 'From: $fromHeaderLine', 'To: $toHeaderLine', 'Call-ID: $callIdHeader', 'CSeq: $cseqHeader', 'Contact: $contactHeader', 'Expires: 300', 'Content-Length: 0', '\r\n'].join('\r\n');

    if (transportType == 'udp' && udpOriginSocket != null) {
      udpOriginSocket.send(utf8.encode(response), clientAddress, clientPort);
    } else if (transportType == 'ws' && wsOriginSocket != null) {
      wsOriginSocket.add(response);
    }
  }
}

void handleInvite(String message, String transportType, RawDatagramSocket? udpOriginSocket, InternetAddress clientAddress, int clientPort, WebSocket? wsOriginSocket) {
  final toUser = RegExp(r'INVITE sip:([^@]+)@').firstMatch(message)?.group(1);
  final fromUser = RegExp(r'From:.*<sip:([^@]+)@').firstMatch(message)?.group(1);
  final callId = RegExp(r'Call-ID: (.*)', caseSensitive: false).firstMatch(message)?.group(1)?.trim();
  if (toUser == null || fromUser == null || callId == null) return;

  activeCalls[callId] = {'from': fromUser, 'to': toUser};
  print("${DateTime.now()}📞 Chamada de '$fromUser' para '$toUser' (Call-ID: $callId) via $transportType");

  proxySipMessage(message, transportType, udpOriginSocket, clientAddress, clientPort, wsOriginSocket);
}

void handleBye(String message, String transportType, RawDatagramSocket? udpOriginSocket, InternetAddress clientAddress, int clientPort, WebSocket? wsOriginSocket) {
  final callId = RegExp(r'Call-ID: (.*)', caseSensitive: false).firstMatch(message)?.group(1)?.trim();
  if (callId == null) return;

  print("${DateTime.now()}👋 Chamada '$callId' finalizada via $transportType.");
  activeCalls.remove(callId);
  proxySipMessage(message, transportType, udpOriginSocket, clientAddress, clientPort, wsOriginSocket);
}

void proxySipMessage(String message, String originalTransportType, RawDatagramSocket? originalUdpSocket, InternetAddress originalClientAddress, int originalClientPort, WebSocket? originalWsSocket) {
  var toUser = RegExp(r'To:.*<sip:([^@]+)@').firstMatch(message)?.group(1);
  var fromUser = RegExp(r'From:.*<sip:([^@]+)@').firstMatch(message)?.group(1);
  String? targetUser;

  // Determinar o destinatário da mensagem.
  // Se for uma requisição (INVITE, BYE, ACK, etc.), o To: header indica o destino.
  // Se for uma resposta (180 Ringing, 200 OK), o From: header na requisição original (que agora seria o To: na resposta) é o destino.
  // Para simplificar, vamos assumir que as respostas são tratadas pelo cliente e o proxy é principalmente para requisições ou mensagens
  // que precisam ser encaminhadas para o outro lado da chamada.

  bool isRequest = !message.startsWith('SIP/2.0'); // Heurística simples para diferenciar request de response

  if (isRequest) {
    targetUser = toUser;
  } else {
    // Para respostas, o "destino" é quem originou a transação,
    // geralmente encontrado no campo 'From' da requisição original,
    // ou no campo 'To' da resposta se estivermos olhando a resposta de volta.
    // Se a mensagem é uma resposta, o `To:` header da resposta aponta para o destino da resposta.
    targetUser = toUser; // O 'To:' numa resposta SIP indica para quem a resposta se destina.

    // No entanto, se esta mensagem for uma resposta sendo encaminhada, e o 'To:' é o proxy/servidor,
    // precisamos olhar para o contexto da chamada ou para outros headers.
    // Por simplicidade, assumimos que 'To:' em uma resposta é o destino correto.
  }
  if (targetUser == null && fromUser != null) {
    // Se não conseguimos determinar um toUser e temos um fromUser (ex: em respostas, pode ser necessário olhar o Via ou Contact)
    // Esta lógica pode precisar de mais refinamento dependendo do fluxo exato das mensagens
    // Para mensagens como ACK que seguem um INVITE, o 'To' é o destinatário.
    // Para respostas (180, 200), o 'To' da resposta é o que originou a requisição.
    // Vamos tentar o fromUser como um fallback se toUser falhar, mas isso pode não ser sempre correto.
    targetUser = fromUser;
  }


  if (targetUser == null) {
    print("${DateTime.now()}⚠️ Não foi possível determinar o usuário de destino para proxy: $message");
    // Se não há targetUser, talvez seja uma mensagem para o próprio servidor (ex: OPTIONS)
    // ou uma resposta a uma requisição originada pelo servidor.
    // Se for uma resposta ao REGISTER, handleRegister já tratou.
    // Se for uma resposta a um OPTIONS do servidor, não implementado.
    // Se for uma resposta a algo que o cliente enviou e o servidor está no "To"
    // e o cliente no "From", enviar de volta ao cliente original.
    if (!isRequest && fromUser != null && originalTransportType == 'udp' && originalUdpSocket != null) {
      // Se é uma resposta, e temos o cliente original UDP, enviamos de volta para ele.
      // Isto é uma suposição, a lógica de proxy real pode ser mais complexa.
      final originalClientInfo = onlineUsers[fromUser];
      if (originalClientInfo != null && originalClientInfo['type'] == 'udp') {
        print("${DateTime.now()}↪️ Encaminhando resposta para o originador UDP '$fromUser'");
        originalUdpSocket.send(utf8.encode(message), originalClientInfo['address'], originalClientInfo['port']);
        return;
      } else if (originalClientInfo != null && originalClientInfo['type'] == 'ws') {
        print("${DateTime.now()}↪️ Encaminhando resposta para o originador WS '$fromUser'");
        originalClientInfo['socket'].add(message);
        return;
      }
    }
    return;
  }

  final targetDetails = onlineUsers[targetUser];
  if (targetDetails != null) {
    if (targetDetails['type'] == 'udp') {
      final targetAddress = targetDetails['address'] as InternetAddress;
      final targetPort = targetDetails['port'] as int;
      print("${DateTime.now()}➡️ Encaminhando mensagem SIP para '$targetUser' (UDP ${targetAddress.address}:$targetPort)");
      if (udpSocket == null) { // udpSocket é o socket do servidor UDP
        print("${DateTime.now()}❌ Erro Crítico: udpSocket não está inicializado para proxy para UDP.");
        return;
      }
      udpSocket!.send(utf8.encode(message), targetAddress, targetPort);
    } else if (targetDetails['type'] == 'ws') {
      final targetWsSocket = targetDetails['socket'] as WebSocket;
      print("${DateTime.now()}➡️ Encaminhando mensagem SIP para '$targetUser' (WebSocket)");
      targetWsSocket.add(message);
    }
  } else {
    print("${DateTime.now()}⚠️ Usuário de destino '$targetUser' não encontrado ou offline para proxy.");
    // Poderia enviar um 404 Not Found de volta para o originador se for uma requisição
    if (isRequest) {
      sendSipErrorResponse("404 Not Found", message, originalTransportType, originalUdpSocket, originalClientAddress, originalClientPort, originalWsSocket);
    }
  }
}

void sendSipErrorResponse(String errorResponseLine, String originalMessage, String transportType, RawDatagramSocket? udpOriginSocket, InternetAddress clientAddress, int clientPort, WebSocket? wsOriginSocket) {
  // Extrai headers necessários da mensagem original para construir a resposta
  final viaLine = RegExp(r'^Via:\s*(.*)$', multiLine: true).firstMatch(originalMessage)?.group(1)?.trim();
  final fromHeaderLine = RegExp(r'^From:\s*(.*)$', multiLine: true).firstMatch(originalMessage)?.group(1)?.trim();
  final toHeaderLine = RegExp(r'^To:\s*(.*)$', multiLine: true).firstMatch(originalMessage)?.group(1)?.trim();
  final callIdHeader = RegExp(r'^Call-ID:\s*(.*)$', multiLine: true).firstMatch(originalMessage)?.group(1)?.trim();
  final cseqHeader = RegExp(r'^CSeq:\s*(.*)$', multiLine: true).firstMatch(originalMessage)?.group(1)?.trim();

  if (viaLine == null || fromHeaderLine == null || toHeaderLine == null || callIdHeader == null || cseqHeader == null) {
    print("${DateTime.now()}❌ Não foi possível construir resposta de erro: faltam headers na mensagem original.");
    return;
  }

  // Adiciona uma tag ao To header se não houver, como é comum em respostas de erro
  String finalToHeaderLine = toHeaderLine;
  if (!toHeaderLine.contains(';tag=')) {
    finalToHeaderLine = '$toHeaderLine;tag=err${DateTime.now().millisecondsSinceEpoch}';
  }

  final response = [
    errorResponseLine, // Ex: "SIP/2.0 404 Not Found"
    'Via: $viaLine',
    'From: $fromHeaderLine',
    'To: $finalToHeaderLine',
    'Call-ID: $callIdHeader',
    'CSeq: $cseqHeader',
    'Content-Length: 0',
    '\r\n'
  ].join('\r\n');

  print("${DateTime.now()}↩️ Enviando resposta de erro: $errorResponseLine para ${clientAddress.address}:$clientPort");

  if (transportType == 'udp' && udpOriginSocket != null) {
    udpOriginSocket.send(utf8.encode(response), clientAddress, clientPort);
  } else if (transportType == 'ws' && wsOriginSocket != null) {
    wsOriginSocket.add(response);
  }
}


// --- FUNÇÃO handleRtp COMPLETA E FUNCIONAL (APENAS PARA UDP) ---
void handleRtp(RawDatagramSocket socket, Datagram datagram) {
  String? fromUser;
  onlineUsers.forEach((user, data) {
    if (data['type'] == 'udp' && data['address'] == datagram.address && data['port'] == datagram.port) {
      fromUser = user;
    }
  });

  if (fromUser == null) return;

  String? toUser;
  activeCalls.forEach((callId, call) {
    if (call['from'] == fromUser) {
      toUser = call['to'];
    } else if (call['to'] == fromUser) {
      toUser = call['from'];
    }
  });

  if (toUser == null) return;

  final target = onlineUsers[toUser];
  if (target != null && target['type'] == 'udp') {
    // RTP só pode ser encaminhado para outro cliente UDP neste modelo simples
    socket.send(datagram.data, target['address'], target['port']);
  }
}