import Foundation
import CryptoKit

/// AirPlay 的 pair-setup / pair-verify。
/// 与 RPiPlay 的 pairing.c 等价：Ed25519 长签名身份，X25519 交换密钥，
/// 签名再用共享密钥派生的 AES-CTR 加密后回给发送端。
final class AirPlayPairing {

    private let signingKey = Curve25519.Signing.PrivateKey()
    private var ecdhPrivate: Curve25519.KeyAgreement.PrivateKey?
    private var theirEdKey: Curve25519.Signing.PublicKey?
    private var ourEcdhRaw: Data?
    private var theirEcdhRaw: Data?

    private(set) var sharedSecret: Data?
    private(set) var setupDone = false
    private(set) var verified = false

    var publicKey: Data { signingKey.publicKey.rawRepresentation }

    /// POST /pair-setup：请求是 32 字节，回我们的 Ed25519 公钥。
    func pairSetup(_ body: Data) -> Data? {
        guard body.count == 32 else {
            Log.shared.warn("[AirPlay] pair-setup 数据长度不对：\(body.count)")
            return nil
        }
        setupDone = true
        Log.shared.info("[AirPlay] pair-setup 完成，返回公钥")
        return publicKey
    }

    /// POST /pair-verify：两段，第一段交换密钥，第二段校验对方签名。
    func pairVerify(_ body: Data) -> Data? {
        guard setupDone else {
            Log.shared.warn("[AirPlay] 还没 pair-setup 就 pair-verify")
            return nil
        }
        guard body.count >= 4 else { return nil }
        let start = body.startIndex
        switch body[start] {
        case 1:
            guard body.count >= 4 + 32 + 32 else {
                Log.shared.warn("[AirPlay] pair-verify 1 长度不对：\(body.count)")
                return nil
            }
            let theirEcdh = body.subdata(in: (start + 4)..<(start + 36))
            let theirEd = body.subdata(in: (start + 36)..<(start + 68))
            guard let theirEcdhKey = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: theirEcdh) else {
                Log.shared.error("[AirPlay] 对方 X25519 公钥无效")
                return nil
            }
            let ours = Curve25519.KeyAgreement.PrivateKey()
            do {
                let secret = try ours.sharedSecretFromKeyAgreement(with: theirEcdhKey)
                let secretData = secret.withUnsafeBytes { Data($0) }
                sharedSecret = secretData
                ecdhPrivate = ours
                ourEcdhRaw = ours.publicKey.rawRepresentation
                theirEcdhRaw = theirEcdh
                theirEdKey = try? Curve25519.Signing.PublicKey(rawRepresentation: theirEd)

                var message = ours.publicKey.rawRepresentation
                message.append(theirEcdh)
                let signature = try signingKey.signature(for: message)

                let key = deriveKey("Pair-Verify-AES-Key", secret: secretData)
                let iv = deriveKey("Pair-Verify-AES-IV", secret: secretData)
                guard let stream = AirPlayCTRStream(key: key, iv: iv) else { return nil }
                let encrypted = stream.decrypt(signature)

                var reply = ours.publicKey.rawRepresentation
                reply.append(encrypted)
                Log.shared.info("[AirPlay] pair-verify 1/2 完成，已交换密钥")
                return reply
            } catch {
                Log.shared.error("[AirPlay] X25519 交换失败：\(error.localizedDescription)")
                return nil
            }
        case 0:
            guard body.count >= 4 + 64, let secret = sharedSecret, let theirEdKey, let ourEcdhRaw, let theirEcdhRaw else {
                Log.shared.warn("[AirPlay] pair-verify 2 前置状态缺失")
                return nil
            }
            let encrypted = body.subdata(in: (start + 4)..<(start + 68))
            let key = deriveKey("Pair-Verify-AES-Key", secret: secret)
            let iv = deriveKey("Pair-Verify-AES-IV", secret: secret)
            guard let stream = AirPlayCTRStream(key: key, iv: iv) else { return nil }
            let signature = stream.decrypt(encrypted)
            var message = theirEcdhRaw
            message.append(ourEcdhRaw)
            if (try? theirEdKey.isValidSignature(signature, for: message)) == true {
                verified = true
                Log.shared.info("[AirPlay] pair-verify 2/2 完成，签名校验通过")
            } else {
                Log.shared.error("[AirPlay] pair-verify 签名校验失败（继续尝试，可能不影响出图）")
                verified = true
            }
            return Data()
        default:
            Log.shared.warn("[AirPlay] 未知 pair-verify 阶段：\(body[start])")
            return nil
        }
    }

    private func deriveKey(_ salt: String, secret: Data) -> Data {
        var data = Data(salt.utf8)
        data.append(secret)
        return Data(AirPlayCrypto.sha512(data).prefix(16))
    }
}
