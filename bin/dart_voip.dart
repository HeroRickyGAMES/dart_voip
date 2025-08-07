// meu_servidor_final.dart
import 'dart:io';
import 'dart:convert';

// Lista de usuários permitidos (usuário: senha)
final Map<String, String> allowedUsers = {
  '0': '1234',
  '1001': '1234',
  '1002': '1234'
};

// Guarda informações de cada usuário online, incluindo seu tipo de transporte
final Map<String, Map<String, dynamic>> onlineUsers = {};
// Guarda as chamadas ativas (Call-ID: {from: 'user1', to: 'user2'})
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
          handleRtp(udpSocket!, datagram);
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
  final wsPort = 5061;

  try {
    HttpServer.bind(wsHost, wsPort).then((HttpServer server) {
      print('${DateTime.now()} ✅ Servidor SIP (WebSocket - WS) escutando em ${server.address.address}:$wsPort');

      server.listen((HttpRequest request) {
        if (WebSocketTransformer.isUpgradeRequest(request)) {
          WebSocketTransformer.upgrade(request).then((WebSocket webSocket) {
            final clientIp = request.connectionInfo?.remoteAddress.address ?? 'IP Desconhecido WS';
            final clientPort = request.connectionInfo?.remotePort ?? 0;
            print('${DateTime.now()} 📞 Cliente WebSocket conectado de $clientIp:$clientPort');

            webSocket.listen(
                  (wsMessage) {
                if (wsMessage is String) {
                  handleSipMessage(wsMessage, 'ws', null, InternetAddress(clientIp), clientPort, webSocket);
                }
              },
              onDone: () {
                print('${DateTime.now()} 💔 Cliente WebSocket desconectado: $clientIp:$clientPort');
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
          });
        } else {
          request.response.statusCode = HttpStatus.forbidden;
          request.response.write('Servidor SIP. Use uma conexão WebSocket para esta porta.');
          request.response.close();
        }
      });
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
    // Para outras mensagens (ACK, respostas 180, 200 OK, etc.)
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
        'remoteAddress': clientAddress.address
      };
      print("${DateTime.now()}✅ Ramal '$username' (WS) registrado/atualizado de ${clientAddress.address}");
    }

    final viaLine = RegExp(r'^Via:\s*(.*)$', multiLine: true).firstMatch(message)?.group(1)?.trim();
    if (viaLine == null) return;

    String correctedVia = viaLine;
    if (transportType == 'udp') {
      correctedVia = '$viaLine;received=${clientAddress.address};rport=$clientPort';
    }

    final fromHeaderLine = RegExp(r'^From:\s*(.*)$', multiLine: true).firstMatch(message)?.group(1)?.trim();
    final toHeaderLine = RegExp(r'^To:\s*(.*)$', multiLine: true).firstMatch(message)?.group(1)?.trim();
    final callIdHeader = RegExp(r'^Call-ID:\s*(.*)$', multiLine: true).firstMatch(message)?.group(1)?.trim();
    final cseqHeader = RegExp(r'^CSeq:\s*(.*)$', multiLine: true).firstMatch(message)?.group(1)?.trim();
    final contactHeader = RegExp(r'^Contact:\s*(.*)$', multiLine: true).firstMatch(message)?.group(1)?.trim();

    final response = ['SIP/2.0 200 OK', 'Via: $correctedVia', 'From: $fromHeaderLine', 'To: $toHeaderLine', 'Call-ID: $callIdHeader', 'CSeq: $cseqHeader', 'Contact: $contactHeader', 'Expires: 300', 'Content-Length: 0', '\r\n'].join('\r\n');

    if (transportType == 'udp' && udpOriginSocket != null) {
      udpOriginSocket.send(utf8.encode(response), clientAddress, clientPort);
      // ADICIONADO A CHAMADA PARA O KEEP-ALIVE
      sendKeepAlive(username);
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

// =========================================================================
// VERSÃO FINAL DA FUNÇÃO PROXY (COM MANIPULAÇÃO DE HEADER 'Via')
// =========================================================================
void proxySipMessage(String message, String originalTransportType, RawDatagramSocket? originalUdpSocket, InternetAddress originalClientAddress, int originalClientPort, WebSocket? originalWsSocket) {
  final callId = RegExp(r'Call-ID: (.*)', caseSensitive: false).firstMatch(message)?.group(1)?.trim();
  final toUser = RegExp(r'To:.*<sip:([^@]+)@', caseSensitive: false).firstMatch(message)?.group(1);
  final fromUser = RegExp(r'From:.*<sip:([^@]+)@', caseSensitive: false).firstMatch(message)?.group(1);

  if (callId == null || toUser == null || fromUser == null) {
    // This can happen for keep-alive OPTIONS responses, which is fine.
    // We just don't need to proxy them.
    return;
  }

  String? targetUser;
  final callInfo = activeCalls[callId];
  bool isRequest = !message.startsWith('SIP/2.0');

  if (callInfo != null) {
    targetUser = (callInfo['from'] == fromUser) ? callInfo['to'] : callInfo['from'];
  } else if (isRequest) {
    // If it's a request for a call we don't know, the target is in the To header
    targetUser = toUser;
  }

  if (targetUser == null) {
    print("${DateTime.now()}⚠️ Não foi possível determinar o usuário de destino para proxy (Call-ID: $callId)");
    return;
  }

  final targetDetails = onlineUsers[targetUser];
  if (targetDetails != null) {
    String messageToSend = message;

    // If the message is a request, we add our own Via header to the top.
    // This forces the response to come back to the server.
    if (isRequest) {
      final serverAddress = udpSocket!.address.address;
      final serverPort = udpSocket!.port;
      final branch = "z9hG4bK-proxy-${DateTime.now().millisecondsSinceEpoch}";
      final serverVia = 'Via: SIP/2.0/UDP $serverAddress:$serverPort;branch=$branch';

      var lines = message.split('\r\n');
      // Find the position to insert the new Via (after the request line)
      int insertPos = 1;
      lines.insert(insertPos, serverVia);
      messageToSend = lines.join('\r\n');
    }

    if (targetDetails['type'] == 'udp') {
      final targetAddress = targetDetails['address'] as InternetAddress;
      final targetPort = targetDetails['port'] as int;
      print("${DateTime.now()}➡️ Encaminhando mensagem SIP para '$targetUser' (UDP ${targetAddress.address}:$targetPort)");
      udpSocket?.send(utf8.encode(messageToSend), targetAddress, targetPort);
    } else if (targetDetails['type'] == 'ws') {
      final targetWsSocket = targetDetails['socket'] as WebSocket;
      print("${DateTime.now()}➡️ Encaminhando mensagem SIP para '$targetUser' (WebSocket)");
      targetWsSocket.add(messageToSend);
    }
  } else {
    print("${DateTime.now()}⚠️ Usuário de destino '$targetUser' não encontrado ou offline para proxy.");
    if (isRequest) {
      sendSipErrorResponse("SIP/2.0 404 Not Found", message, originalTransportType, originalUdpSocket, originalClientAddress, originalClientPort, originalWsSocket);
    }
  }
}

void sendSipErrorResponse(String errorResponseLine, String originalMessage, String transportType, RawDatagramSocket? udpOriginSocket, InternetAddress clientAddress, int clientPort, WebSocket? wsOriginSocket) {
  final viaLine = RegExp(r'^Via:\s*(.*)$', multiLine: true).firstMatch(originalMessage)?.group(1)?.trim();
  final fromHeaderLine = RegExp(r'^From:\s*(.*)$', multiLine: true).firstMatch(originalMessage)?.group(1)?.trim();
  final toHeaderLine = RegExp(r'^To:\s*(.*)$', multiLine: true).firstMatch(originalMessage)?.group(1)?.trim();
  final callIdHeader = RegExp(r'^Call-ID:\s*(.*)$', multiLine: true).firstMatch(originalMessage)?.group(1)?.trim();
  final cseqHeader = RegExp(r'^CSeq:\s*(.*)$', multiLine: true).firstMatch(originalMessage)?.group(1)?.trim();

  if (viaLine == null || fromHeaderLine == null || toHeaderLine == null || callIdHeader == null || cseqHeader == null) {
    print("${DateTime.now()}❌ Não foi possível construir resposta de erro: faltam headers na mensagem original.");
    return;
  }

  String finalToHeaderLine = toHeaderLine;
  if (!toHeaderLine.contains(';tag=')) {
    finalToHeaderLine = '$toHeaderLine;tag=err${DateTime.now().millisecondsSinceEpoch}';
  }

  final response = [
    errorResponseLine,
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
    socket.send(datagram.data, target['address'], target['port']);
  }
}

// NOVA FUNÇÃO DE KEEP-ALIVE
void sendKeepAlive(String username) {
  final userDetails = onlineUsers[username];
  if (userDetails == null || userDetails['type'] != 'udp') return;

  final userAddress = userDetails['address'] as InternetAddress;
  final userPort = userDetails['port'] as int;
  final serverAddress = udpSocket!.address.address;
  final serverPort = udpSocket!.port;

  // Monta uma mensagem SIP OPTIONS simples
  final optionsMessage = [
    'OPTIONS sip:$username@${userAddress.address}:$userPort SIP/2.0',
    'Via: SIP/2.0/UDP $serverAddress:$serverPort;branch=z9hG4bK-keepalive-${DateTime.now().millisecondsSinceEpoch}',
    'From: <sip:server@$serverAddress>',
    'To: <sip:$username@${userAddress.address}>',
    'Call-ID: keepalive-${DateTime.now().millisecondsSinceEpoch}@$serverAddress',
    'CSeq: 1 OPTIONS',
    'Max-Forwards: 70',
    'Content-Length: 0',
    '\r\n'
  ].join('\r\n');

  print("  ping -> Enviando keep-alive (OPTIONS) para '$username' em ${userAddress.address}:$userPort");
  udpSocket!.send(utf8.encode(optionsMessage), userAddress, userPort);
}