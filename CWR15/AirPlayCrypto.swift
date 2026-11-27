import Foundation
import CommonCrypto
import CryptoKit

/// AirPlay 用到的几个基础密码学操作。
enum AirPlayCrypto {

    static func hex(_ text: String) -> Data {
        var bytes: [UInt8] = []
        var index = text.startIndex
        while index < text.endIndex {
            guard let next = text.index(index, offsetBy: 2, limitedBy: text.endIndex) else { break }
            if let value = UInt8(text[index..<next], radix: 16) { bytes.append(value) }
            index = next
        }
        return Data(bytes)
    }

    static func sha1(_ data: Data) -> Data {
        Data(Insecure.SHA1.hash(data: data))
    }

    static func sha512(_ data: Data) -> Data {
        Data(SHA512.hash(data: data))
    }
}

/// 连续的 AES-128-CTR 密钥流，行为与 RPiPlay 的 mirror_buffer 一致：
/// 每个包从整块边界重新开始，不足 16 字节的尾巴用当前块剩下的密钥字节异或，并把剩下的留到下一个包。
final class AirPlayCTRStream {

    private var cryptor: CCCryptorRef?
    private var carryCount = 0
    private var carryKeys = [UInt8](repeating: 0, count: 16)

    init?(key: Data, iv: Data) {
        guard key.count == 16, iv.count == 16 else { return nil }
        var created: CCCryptorRef?
        let status = key.withUnsafeBytes { keyBytes -> CCCryptorStatus in
            iv.withUnsafeBytes { ivBytes -> CCCryptorStatus in
                CCCryptorCreateWithMode(
                    CCOperation(kCCEncrypt),
                    CCMode(kCCModeCTR),
                    CCAlgorithm(kCCAlgorithmAES),
                    CCPadding(ccNoPadding),
                    ivBytes.baseAddress,
                    keyBytes.baseAddress,
                    key.count,
                    nil, 0, 0,
                    CCModeOptions(kCCModeOptionCTR_BE),
                    &created)
            }
        }
        guard status == kCCSuccess, let created else {
            Log.shared.error("[AirPlay] AES-CTR 初始化失败：\(status)")
            return nil
        }
        cryptor = created
    }

    deinit {
        if let cryptor { CCCryptorRelease(cryptor) }
    }

    func reset() {
        carryCount = 0
        carryKeys = [UInt8](repeating: 0, count: 16)
    }

    func decrypt(_ input: Data) -> Data {
        guard let cryptor, !input.isEmpty else { return input }
        let count = input.count
        var output = [UInt8](repeating: 0, count: count)

        input.withUnsafeBytes { rawInput in
            output.withUnsafeMutableBytes { rawOutput in
                guard let src = rawInput.bindMemory(to: UInt8.self).baseAddress,
                      let dst = rawOutput.bindMemory(to: UInt8.self).baseAddress else { return }

                var offset = 0
                if carryCount > 0 {
                    let used = min(carryCount, count)
                    for i in 0..<used {
                        dst[i] = src[i] ^ carryKeys[(16 - carryCount) + i]
                    }
                    offset = used
                    carryCount = 0
                }

                let rest = count - offset
                let wholeBlocks = (rest / 16) * 16
                if wholeBlocks > 0 {
                    var moved = 0
                    let status = CCCryptorUpdate(cryptor, src + offset, wholeBlocks, dst + offset, wholeBlocks, &moved)
                    if status != kCCSuccess {
                        Log.shared.error("[AirPlay] AES-CTR 解密失败：\(status)")
                        return
                    }
                    offset += wholeBlocks
                }

                let remaining = count - offset
                if remaining > 0 {
                    var zeros = [UInt8](repeating: 0, count: 16)
                    var keystream = [UInt8](repeating: 0, count: 16)
                    var moved = 0
                    zeros.withUnsafeBytes { zRaw in
                        keystream.withUnsafeMutableBytes { kRaw in
                            guard let z = zRaw.bindMemory(to: UInt8.self).baseAddress,
                                  let k = kRaw.bindMemory(to: UInt8.self).baseAddress else { return }
                            _ = CCCryptorUpdate(cryptor, z, 16, k, 16, &moved)
                        }
                    }
                    for i in 0..<remaining {
                        dst[offset + i] = src[offset + i] ^ keystream[i]
                    }
                    carryKeys = keystream
                    carryCount = 16 - remaining
                }
            }
        }
        return Data(output)
    }
}
