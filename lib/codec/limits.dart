/// MeshPix application `data_type` in the MeshCore developer range (0xFF00–0xFFFE).
const int kMeshPixDataType = 0xFF50;

/// Channel datagram payload cap from companion protocol (`MAX_CHANNEL_DATA_LENGTH`).
const int kMaxDatagramPayload = 163;

/// Hard cap on upgrade chunks (fits in a 16-bit NACK bitmap).
const int kMaxUpgradeChunks = 16;

const int kMp1Version = 1;
const int kMp1Magic0 = 0x4D; // M
const int kMp1Magic1 = 0x50; // P

const int kPreviewTarget = 24;
const int kUpgradeTarget = 48;
