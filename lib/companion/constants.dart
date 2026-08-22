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
  static const getDeviceTime = 0x05;
  static const setDeviceTime = 0x06;
  static const sendSelfAdvert = 0x07;
  static const setAdvertName = 0x08;
  static const addUpdateContact = 0x09;
  static const syncNextMessage = 0x0A;
  static const setRadioParams = 0x0B;
  static const setRadioTxPower = 0x0C;
  static const resetPath = 0x0D;
  static const setAdvertLatLon = 0x0E;
  static const removeContact = 0x0F;
  static const shareContact = 0x10;
  static const exportContact = 0x11;
  static const importContact = 0x12;
  static const reboot = 0x13;
  static const getBattAndStorage = 0x14;
  static const deviceQuery = 0x16;
  static const sendRawData = 0x19;
  static const sendLogin = 0x1A;
  static const sendStatusReq = 0x1B;
  static const getChannel = 0x1F;
  static const setChannel = 0x20;
  static const sendTracePath = 0x24;
  static const sendTelemetryReq = 0x27;
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
  static const currTime = 0x09;
  static const noMoreMsgs = 0x0A;
  static const exportContact = 0x0B;
  static const battAndStorage = 0x0C;
  static const deviceInfo = 0x0D;
  static const contactMsgRecvV3 = 0x10;
  static const channelMsgRecvV3 = 0x11;
  static const channelInfo = 0x12;
  static const channelDataRecv = 0x1B;
  static const advert = 0x80;
  static const pathUpdated = 0x81;
  static const sendConfirmed = 0x82;
  static const msgWaiting = 0x83;
  static const rawData = 0x84;
  static const loginSuccess = 0x85;
  static const loginFail = 0x86;
  static const statusResponse = 0x87;
  static const traceData = 0x89;
  static const newAdvert = 0x8A;
  static const telemetryResponse = 0x8B;
}

class TxtType {
  static const plain = 0;
  static const cli = 1;
  static const signedPlain = 2;
}
