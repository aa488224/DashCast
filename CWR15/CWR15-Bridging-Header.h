#ifndef DashCast_Bridging_Header_h
#define DashCast_Bridging_Header_h

/// PlayFair 的 FairPlay 密钥推导（纯 C，来自 RPiPlay 的 playfair 实现）。
void playfair_decrypt(unsigned char *message3, unsigned char *cipherText, unsigned char *keyOut);

#endif /* DashCast_Bridging_Header_h */
