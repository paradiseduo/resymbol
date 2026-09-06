import Foundation

enum MachOPointerFormat {
    case plain
    case arm64eAuthenticated
}

enum MachOAddressDomain {
    case absoluteVM
    case imageRelative
}

struct MachOAddressResolver {
    let file: MachOFile
    let data: Data

    var imageBase: UInt64 { file.preferredLoadAddress }

    func fileOffset(forVMAddress address: UInt64) -> Int? {
        file.fileOffset(forVMAddress: address)
    }

    func vmAddress(forFileOffset offset: Int) -> UInt64? {
        guard offset >= 0 else { return nil }
        return file.segments.first(where: {
            UInt64(offset) >= $0.fileoff && UInt64(offset) - $0.fileoff < $0.filesize
        }).map { $0.vmaddr + UInt64(offset) - $0.fileoff }
    }

    func vmAddress(forImageOffset offset: UInt64) -> UInt64? {
        let (address, overflow) = imageBase.addingReportingOverflow(offset)
        return overflow ? nil : address
    }

    func imageOffset(forVMAddress address: UInt64) -> UInt64? {
        address >= imageBase ? address - imageBase : nil
    }

    func chainedFixupLocation(segmentOffset: UInt64, pageOffset: UInt64) -> (fileOffset: Int, vmAddress: UInt64)? {
        let (imageOffset, overflow) = segmentOffset.addingReportingOverflow(pageOffset)
        guard !overflow, let vmAddress = vmAddress(forImageOffset: imageOffset),
              let fileOffset = fileOffset(forVMAddress: vmAddress) else { return nil }
        return (fileOffset, vmAddress)
    }

    func chainedRebaseTarget(_ target: UInt64, high8: UInt8 = 0,
                             domain: MachOAddressDomain) -> UInt64 {
        let unpacked = target | (UInt64(high8) << 56)
        switch domain {
        case .absoluteVM:
            return unpacked
        case .imageRelative:
            // dyld uses wrapping unsigned arithmetic here because high8 may
            // carry top-byte pointer metadata.
            return imageBase &+ unpacked
        }
    }

    func stripPointerAuthentication(_ raw: UInt64, format: MachOPointerFormat = .plain) -> UInt64 {
        switch format {
        case .plain:
            return raw
        case .arm64eAuthenticated:
            // The authenticated pointer payload retains the low 56 address
            // bits; PAC/top-byte bits must not participate in VM mapping.
            return raw & 0x00ff_ffff_ffff_ffff
        }
    }

    func resolveAbsolutePointer(_ raw: UInt64, format: MachOPointerFormat = .plain) -> Int? {
        let value = stripPointerAuthentication(raw, format: format)
        return fileOffset(forVMAddress: value) ?? (value <= UInt64(Int.max) && Int(value) < data.count ? Int(value) : nil)
    }

    func resolveRelativePointer(fieldOffset: Int, raw: UInt32) -> Int? {
        let delta = Int(Int32(bitPattern: raw))
        // Relative pointers are defined in the loaded image's address
        // domain. Adding the delta to a file offset only works when the
        // source and target happen to share the same file/VM displacement;
        // that is not true across segments with holes or zero-fill tails.
        if let fieldAddress = vmAddress(forFileOffset: fieldOffset) {
            let signedDelta = Int64(delta)
            let signedTarget: UInt64
            if signedDelta < 0 {
                let magnitude = UInt64(-signedDelta)
                guard fieldAddress >= magnitude else { return nil }
                signedTarget = fieldAddress - magnitude
            } else {
                let (target, overflow) = fieldAddress.addingReportingOverflow(UInt64(signedDelta))
                guard !overflow else { return nil }
                signedTarget = target
            }
            if let target = fileOffset(forVMAddress: signedTarget) {
                return target
            }
            // Once the source field is known to be mapped, an unmapped VM
            // target is invalid. Do not fall back to an unrelated file offset
            // and turn a malformed pointer into a plausible record.
            return nil
        }

        // Keep the bounded file-offset fallback for synthetic data and for
        // legacy callers that do not have a segment mapping installed.
        let (target, overflow) = fieldOffset.addingReportingOverflow(delta)
        guard !overflow, target >= 0, target < data.count else { return nil }
        return target
    }

    /// Resolve a relative pointer and clear ABI tag bits from the resulting
    /// file offset. Swift descriptor records are 4-byte aligned, while the
    /// old parser applied this masking ad hoc after every lookup.
    func resolveAlignedRelativePointer(fieldOffset: Int, raw: UInt32,
                                       alignment: Int = 4) -> Int? {
        guard alignment > 0, alignment & (alignment - 1) == 0,
              let target = resolveRelativePointer(fieldOffset: fieldOffset, raw: raw) else {
            return nil
        }
        let aligned = target & ~(alignment - 1)
        guard aligned < data.count else { return nil }
        return aligned
    }

    func resolveAlignedRelativePointer(fieldOffset: Int, rawHex: String,
                                       alignment: Int = 4) -> Int? {
        guard let raw = UInt32(rawHex, radix: 16) else { return nil }
        return resolveAlignedRelativePointer(fieldOffset: fieldOffset, raw: raw,
                                             alignment: alignment)
    }

    func resolveRelativePointer(fieldOffset: Int, rawHex: String) -> Int? {
        guard let raw = UInt32(rawHex, radix: 16) else { return nil }
        return resolveRelativePointer(fieldOffset: fieldOffset, raw: raw)
    }

    func resolveIndirectRelativePointer(fieldOffset: Int, raw: UInt32) -> Int? {
        // Swift RelativeIndirectablePointer reserves bit 0 as the indirect
        // tag. The remaining 31 bits are a signed field-relative offset.
        let isIndirect = (raw & 1) != 0
        let relativeBits = raw & ~UInt32(1)
        guard let pointerOffset = resolveRelativePointer(fieldOffset: fieldOffset, raw: relativeBits) else { return nil }
        if !isIndirect { return pointerOffset }
        if data.count >= 8, pointerOffset <= data.count - 8 {
            let value = data[pointerOffset..<pointerOffset + 8].enumerated().reduce(UInt64(0)) {
                $0 | (UInt64($1.element) << UInt64($1.offset * 8))
            }
            if let absolute = resolveAbsolutePointer(value, format: .arm64eAuthenticated) { return absolute }
        }
        guard data.count >= 4, pointerOffset <= data.count - 4 else { return nil }
        let value = data[pointerOffset..<pointerOffset + 4].enumerated().reduce(UInt32(0)) {
            $0 | (UInt32($1.element) << UInt32($1.offset * 8))
        }
        return resolveRelativePointer(fieldOffset: pointerOffset, raw: value)
    }
}
