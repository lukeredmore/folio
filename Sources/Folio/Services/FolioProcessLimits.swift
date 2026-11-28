import Darwin
import Foundation

public enum FolioProcessLimits {
    public static let rlimInfinity = rlim_t(Int64.max)
    public static let desiredSoftOpenFileLimit: rlim_t = 65_536
    public static let reservedDescriptorHeadroom: Int = 128

    public static func kernelMaxFilesPerProcess() -> rlim_t {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("kern.maxfilesperproc", &value, &size, nil, 0) == 0, value > 0 {
            return rlim_t(value)
        }
        return rlim_t(OPEN_MAX)
    }

    public static func targetSoftOpenFileLimit(
        currentSoft: rlim_t,
        hardLimit: rlim_t,
        kernelMaxPerProc: rlim_t,
        desired: rlim_t = desiredSoftOpenFileLimit
    ) -> rlim_t? {
        let effectiveKernelCap = kernelMaxPerProc > 0 ? kernelMaxPerProc : rlim_t(OPEN_MAX)
        var ceiling = min(desired, effectiveKernelCap)
        if hardLimit != rlimInfinity {
            ceiling = min(ceiling, hardLimit)
        }
        return ceiling > currentSoft ? ceiling : nil
    }

    @discardableResult
    public static func raiseOpenFileLimitIfNeeded() -> Int {
        var limit = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &limit) == 0 else {
            return Int(OPEN_MAX)
        }
        let kernelCap = kernelMaxFilesPerProcess()
        if let target = targetSoftOpenFileLimit(
            currentSoft: limit.rlim_cur,
            hardLimit: limit.rlim_max,
            kernelMaxPerProc: kernelCap,
            desired: desiredSoftOpenFileLimit
        ) {
            var updated = rlimit(rlim_cur: target, rlim_max: limit.rlim_max)
            if setrlimit(RLIMIT_NOFILE, &updated) != 0 {
                let originalSoft = limit.rlim_cur
                var requested =
                    targetSoftOpenFileLimit(
                        currentSoft: originalSoft,
                        hardLimit: limit.rlim_max,
                        kernelMaxPerProc: kernelCap,
                        desired: rlim_t(OPEN_MAX)
                    ) ?? target
                while requested > originalSoft {
                    var candidate = rlimit(rlim_cur: requested, rlim_max: limit.rlim_max)
                    if setrlimit(RLIMIT_NOFILE, &candidate) == 0 {
                        break
                    }
                    if errno != EINVAL || requested <= originalSoft + 1 {
                        break
                    }
                    requested = originalSoft + (requested - originalSoft) / 2
                }
            }
        }
        return currentSoftOpenFileLimit()
    }

    public static func currentSoftOpenFileLimit() -> Int {
        var limit = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &limit) == 0 else {
            return 256
        }
        return clampedDescriptorCount(limit.rlim_cur)
    }

    private static func clampedDescriptorCount(_ value: rlim_t) -> Int {
        let maxSafe = rlim_t(Int.max / 2)
        return Int(min(value, maxSafe))
    }
}
