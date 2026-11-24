import Foundation
import Security
import CryptoKit

/// Certificate pinning for the Hyperliquid API (REST and WebSocket): besides the normal iOS check, the
/// server's chain must lead to one of a few well-known root CAs. A certificate from any other CA — for
/// example a root installed on the phone by a profile, a corporate proxy or a hostile network — is refused,
/// even though iOS would trust it. Hyperliquid's certificate is issued by Amazon; the other roots are kept
/// as backups in case it moves to another major CA. The check can be turned off in Settings.
enum CertificatePinning {
    static let hosts: Set<String> = ["api.hyperliquid.xyz"]

    /// SHA-256 of the SubjectPublicKeyInfo (base64), as in HPKP / TrustKit.
    static let pins: Set<String> = [
        "++MBgDH5WGvL9Bcn5Be30cRcL0f5O+NyoXuWtQdX1aI=",   // Amazon Root CA 1 (current chain)
        "f0KW/FtqTjs108NpYj42SrGvOB2PpxIVM8nWxjPqJGE=",   // Amazon Root CA 2
        "NqvDJlas/GRcYbcWE8S/IceH9cq77kg0jVhZeAPXq8k=",   // Amazon Root CA 3
        "9+ze1cZgR9KO1kZrVDxA4HQ6voHRCSVNz4RdTCx4U8U=",   // Amazon Root CA 4
        "KwccWaCgrnaw6tsrrSO61FgLacNgG2MMLq8GE6+oP5I=",   // Starfield Services Root G2 (cross-signs Amazon)
        "C5+lpZ7tcVwmwQIMcRtPbsQtWLABXhQzejna0wHFr8M=",   // ISRG Root X1 (Let's Encrypt)
        "diGVwiVYbubAI3RW4hB9xU8e/CH2GnkuvVFZE8zmgzI=",   // ISRG Root X2
        "hxqRlPTu1bMS/0DITB1SSu0vd4u/8l8TjPgfaAp63Gc=",   // GTS Root R1 (Google)
        "QXnt2YHvdHR3tJYmQIr0Paosp6t/nggsEGD4QJZ3Q0g=",   // GTS Root R3
        "mEflZT5enoR1FuXLgYYGqnVEoZvmf9c2bVBpiOjYQ0c=",   // GTS Root R4
        "i7WTqTvh0OioIruIfFR4kMPnBqrS2rdiVPl/s2uC/CY=",   // DigiCert Global Root G2
    ]

    static let enabledKey = "certPinning"
    static var enabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var lastFailure: Date?

    /// True shortly after a connection was refused by the pin check (to explain the error).
    static var failedRecently: Bool {
        lock.lock(); defer { lock.unlock() }
        return lastFailure.map { Date().timeIntervalSince($0) < 10 } ?? false
    }

    static var failureMessage: String {
        L("Secure connection check failed: the server's certificate is not one Hyperliquid uses. Someone may be intercepting the connection (public Wi-Fi, a VPN or a profile installed on the phone). Switch networks. If you trust this network, the check can be turned off in Settings → Security.")
    }

    /// Server-trust decision for a challenge; nil = not a pinned host (default handling).
    static func evaluate(_ challenge: URLAuthenticationChallenge) -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        let space = challenge.protectionSpace
        guard space.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = space.serverTrust, hosts.contains(space.host.lowercased()), enabled
        else { return (.performDefaultHandling, nil) }
        if isPinned(trust) { return (.useCredential, URLCredential(trust: trust)) }
        lock.lock(); lastFailure = Date(); lock.unlock()
        return (.cancelAuthenticationChallenge, nil)
    }

    static func isPinned(_ trust: SecTrust) -> Bool {
        var error: CFError?
        guard SecTrustEvaluateWithError(trust, &error),
              let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate] else { return false }
        return chain.contains { spkiHash($0).map(pins.contains) ?? false }
    }

    private static let rsa2048: [UInt8] = hex("30820122300d06092a864886f70d01010105000382010f00")
    private static let rsa4096: [UInt8] = hex("30820222300d06092a864886f70d01010105000382020f00")
    private static let ecP256: [UInt8] = hex("3059301306072a8648ce3d020106082a8648ce3d030107034200")
    private static let ecP384: [UInt8] = hex("3076301006072a8648ce3d020106052b81040022036200")

    /// SecKey gives the raw key (PKCS#1 for RSA, X9.63 point for EC); the SPKI is that key behind the
    /// fixed ASN.1 header for its type and size.
    static func spkiHash(_ cert: SecCertificate) -> String? {
        guard let key = SecCertificateCopyKey(cert),
              let attrs = SecKeyCopyAttributes(key) as? [CFString: Any],
              let type = attrs[kSecAttrKeyType] as? String,
              let bits = attrs[kSecAttrKeySizeInBits] as? Int,
              let raw = SecKeyCopyExternalRepresentation(key, nil) as Data? else { return nil }
        let header: [UInt8]
        if type == (kSecAttrKeyTypeRSA as String) {
            switch bits { case 2048: header = rsa2048; case 4096: header = rsa4096; default: return nil }
        } else if type == (kSecAttrKeyTypeECSECPrimeRandom as String) {
            switch bits { case 256: header = ecP256; case 384: header = ecP384; default: return nil }
        } else {
            return nil
        }
        return Data(SHA256.hash(data: Data(header) + raw)).base64EncodedString()
    }

    private static func hex(_ s: String) -> [UInt8] {
        var out: [UInt8] = []
        var i = s.startIndex
        while i < s.endIndex {
            let j = s.index(i, offsetBy: 2)
            out.append(UInt8(s[i..<j], radix: 16)!)
            i = j
        }
        return out
    }
}

/// Session delegate applying the pin check; used by the API client and the WebSocket.
final class PinnedSessionDelegate: NSObject, URLSessionDelegate {
    static let shared = PinnedSessionDelegate()

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let r = CertificatePinning.evaluate(challenge)
        completionHandler(r.0, r.1)
    }
}
