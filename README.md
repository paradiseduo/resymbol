# resymbol

`resymbol` parses 64-bit Apple Mach-O files and recovers Objective-C/Swift
declarations and as much of the stripped symbol table as the binary proves.
It supports `arm64`, `arm64e`, and `x86_64`; 32-bit Mach-O is not supported.

## Build

```sh
./build-macOS_arm.sh   # Apple Silicon
./build-macOS_x86.sh   # Intel Mac
```

## Usage

```text
resymbol <mach-o> [--objc | --swift]
         [--json <file>]
         [--output-dir <directory>]
         [--restore-symbols [--restore-output <file>]]
         [--verbose]
```

The executable inside an app bundle is the input, for example:

```sh
./resymbol Payload/App.app/App > recovered.txt
```

With no language flag, Objective-C and Swift are both parsed. Use `--objc` or
`--swift` to restrict parsing to one language. The parser output remains the
same declaration-style text that was previously printed to the console.

When `--verbose` is supplied together with `--output-dir` or
`--restore-symbols`, progress is written to `stderr` so it does not corrupt
declarations or JSON. Progress is disabled by default. Long-running stages show
the current phase, percentage, item count when available, elapsed time, and an
estimated remaining time; stages without a reliable total continue to show an
activity line until completion.

### JSON symbol export

Export the recovered symbol candidates in the legacy-compatible format:

```sh
./resymbol Payload/App.app/App --json symbols.json
```

The output is an array of `{ "name": "...", "address": "0x..." }` records.
Addresses are Mach-O VM addresses, not file offsets.

### Declaration files

Write one file per recovered declaration instead of stdout:

```sh
./resymbol Payload/App.app/App --output-dir ./Recovered

# Add --verbose to show progress on stderr.
./resymbol Payload/App.app/App --output-dir ./Recovered --verbose
```

The directory layout is:

```text
Recovered/
  OC/
    class/*.h
    protocol/*.h
    Extension/*.h
  Swift/
    class/*.swift
    struct/*.swift
    enum/*.swift
    protocol/*.swift
    Extension/*.swift
    block/*.swift
```

Names are sanitized for filesystem use. Duplicate descriptors targeting the
same declaration file are merged, retaining the richer declaration.

### Swift type recovery

Swift field names and types are recovered from runtime metadata and ABI
spellings; a stripped binary does not always preserve the original source
type text. The resolver recognizes optional arrays (`Say...GGSg`), arrays of
protocol existentials (`C_pG`), nested `Dictionary`/`Array`/`Set` containers,
generic substitutions, arbitrary length-prefixed nominal names, and compact
closure forms. It also recovers class-bound protocol compositions, labeled
tuple arrays, and function-valued enum payloads when the typealias spelling is
not present in metadata. Except for Swift standard-library ABI substitutions,
recovery does not use a type-name whitelist. For example:

```swift
SaySo25ModelCGGSg                         // [Model]?
_s10Foundation10URLRequestVMnSg          // URLRequest?
ySo7UIImageC_URL?SaySo21StickerModelCGSgtcSg
                                          // ((UIImage, URL?, [StickerModel]?) -> Void)?
```

Swift block capture records may retain generic-signature constraints rather
than a source parameter name. Constrained arrays and weak/unowned archetypes
are rendered with stable generic placeholders (`T`, `A`, etc.) after
structurally consuming the constraint and ownership suffixes; the parser does
not guess an application type from the constraint text.

Swift lazy backing fields named `$__lazy_storage_$_name` are emitted as
`lazy var name`; Objective-C ivars use the equivalent `lazy` declaration.
Resolution is evidence-driven and token-validated. Unknown or malformed ABI
fragments are retained as unresolved output instead of being guessed from a
property or class name. Low-level block capture records and partially stripped
SwiftUI result-builder types may therefore still contain ABI text when the
binary does not retain enough metadata to prove a source spelling.

### Restore the symbol table

Restore symbols to a new Mach-O and remove the old code signature:

```sh
# Restores the symbol table directly in App. No backup is created.
./resymbol Payload/App.app/App --restore-symbols

# Add --verbose to show progress on stderr.
./resymbol Payload/App.app/App --restore-symbols --verbose

# Explicit output path. The input remains unchanged and is not backed up.
./resymbol Payload/App.app/App \
  --restore-symbols --restore-output /tmp/App.resymbol
```

Without `--restore-output`, the validated rebuilt Mach-O replaces the input
file in place and no backup is created. When `--restore-output` is supplied,
the restored Mach-O is written only to that new path; the input is not touched
and no backup is created. The writer validates the rebuilt nlist and dynamic
symbol tables, clears the old `LC_CODE_SIGNATURE` range, and leaves the result
unsigned. The output must be re-signed separately before execution.

Fat/universal files are parsed using their default `arm64` slice. Symbol
restoration requires a thin Mach-O; use `lipo -thin arm64` first when needed.

