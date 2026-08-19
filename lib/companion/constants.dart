/// Nordic UART Service used by MeshCore companion firmware.
class MeshCoreUuids {
  static const service = '6e400001-b5a3-f393-e0a9-e50e24dcca9e';
  static const rxWrite = '6e400002-b5a3-f393-e0a9-e50e24dcca9e';
  static const txNotify = '6e400003-b5a3-f393-e0a9-e50e24dcca9e';

  static const namePrefixes = [
    'MeshCore-',
    'Whisper-',
    'WisCore-',
    'HT-',
    'LowMesh_MC_',
  ];

  static bool matchesName(String? name) {
    if (name == null || name.isEmpty) return false;
    return namePrefixes.any(name.startsWith);
  }
}

class Cmd {
  static const appStart = 0x01;
  static const sendTxtMsg = 0x02;
  static const sendChannelTxtMsg = 0x03;
  static const getContacts = 0x04;
  static const syncNextMessage = 0x0A;
  static const deviceQuery = 0x16;
  static const sendRawData = 0x19;
  static const getChannel = 0x1F;
  static const sendChannelData = 0x3E;
}

class Resp {
  static const ok = 0x00;
  static const error = 0x01;
  static const contactsStart = 0x02;
  static const contact = 0x03;
  static const contactsEnd = 0x04;
  static const selfInfo = 0x05;
  static const msgSent = 0x06;
  static const contactMsgRecv = 0x07;
  static const channelMsgRecv = 0x08;
  static const noMoreMsgs = 0x0A;
  static const deviceInfo = 0x0D;
  static const contactMsgRecvV3 = 0x10;
  static const channelMsgRecvV3 = 0x11;
  static const channelInfo = 0x12;
  static const channelDataRecv = 0x1B;
  static const rawData = 0x84;
  static const msgWaiting = 0x83;
}

class AdvType {
  static const none = 0;
  static const chat = 1;
  static const repeater = 2;
  static const room = 3;
}
