# resymbol
A reverse engineering tool to restore stripped symbol table and dump Objective-C class or Swift types for iOS app.


## class-dump
```
❯ git clone https://github.com/paradiseduo/resymbol.git
❯ ./build-macOS_x86.sh
❯ ./resymbol
OVERVIEW: resymbol v1.0.0

Restore symbol

USAGE: resymbol <file-path> [--ipa] [--symbol]

ARGUMENTS:
  <file-path>             The machO/IPA to restore symbol.

OPTIONS:
  -i, --ipa               If restore symbol ipa, please set this flag.
                          Default false mean is machO file path.
  -s, --symbol            Dump Symbol Table.
  --version               Show the version.
  -h, --help              Show help information.
```

### Example
```
❯ ./resymbol resymbol > result
❯ cat result
struct Methods {
    let baseMethod: DataStruct
    let elementSize: DataStruct
    let elementCount: DataStruct
    let methods: Swift.Array<Method>?
}

struct MethodName {
    let name: DataStruct
    let methodName: DataStruct
}

struct segment_command_64 {
    let cmd: Swift.UInt32
    let cmdsize: Swift.UInt32
    let segname: Swift.Int8
    let vmaddr: Swift.UInt64
    let vmsize: Swift.UInt64
    let fileoff: Swift.UInt64
    let filesize: Swift.UInt64
    let maxprot: Swift.Int32
    let initprot: Swift.Int32
    let nsects: Swift.UInt32
    let flags: Swift.UInt32
}

struct mach_header_64 {
    let magic: Swift.UInt32
    let cputype: Swift.Int32
    let cpusubtype: Swift.Int32
    let filetype: Swift.UInt32
    let ncmds: Swift.UInt32
    let sizeofcmds: Swift.UInt32
    let flags: Swift.UInt32
    let reserved: Swift.UInt32
}
........
```


## restore symbol table
To do...
