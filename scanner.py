#!/usr/bin/env python3

""" ZigScanner
A python script to enumerate wayland protocol requests and events
"""

from math import log2
from pathlib import Path
from subprocess import check_output
from sys import argv
from xml.etree import ElementTree as ET
from re import match

deprecated = [
    "wl_shell",
    "wl_shell_surface",
]

substitutions = {
    "async",
    "const",
    "error",
    "export",
    "struct",
    "var",
    "type",
    "test",
}

typesubstitutions = {
    "array": "types.Array",
    "int": "i32",
    "fixed": "f64",
    "new_id": "u32",
    "object": "u32",
    "string": "types.String",
    "uint": "u32",
}

definitions = """
pub const String = []const u8;
pub const Array = []const u32;
"""

def commonPrefix(strs: list[str]):
    if not strs:
        return ""

    for i, letters in enumerate(zip(*strs)):
        if len(set(letters)) > 1:
            return strs[0][:i]
    return min(strs, key=len)

def initCaps(string: str) -> str:
    return ''.join(w.title() for w in string.split('_'))

def linkEnum(enum: str, namespace) -> str:
    parts = enum.split('.')
    if len(parts) == 1:
        return initCaps(enum)
    protocol, enum = parts
    return f'{protocol.removeprefix(f'{namespace}_')}.{initCaps(enum)}'

def zigFormat(source: str) -> str:
    return check_output(
        ['zig', 'fmt', '--stdin'],
        input=source,
        text=True
    )

def rename(name: str, namespace: str) -> str:
    prefix = ''
    if name in substitutions or not name[0].isalpha():
        prefix = f"{namespace}_"
    return f"{prefix}{name}"

def argument(element: ET.Element, namespace) -> str:
    name = element.attrib['name']
    tp = element.attrib['type']
    if tp == "fd":
        return ''
    if tp == "uint" and 'enum' in element.attrib:
        return f"{name}: {linkEnum(element.attrib['enum'], namespace)},"
    if tp == "new_id" and "interface" not in element.attrib:
        return f"""
            interface: {typesubstitutions['string']},
            version: {typesubstitutions['uint']},
            {name}: {typesubstitutions[tp]}
        """
    return f"{name}: {typesubstitutions[tp]},"

def method(element: ET.Element, namespace) -> str:
    args = [child for child in element if child.tag == 'arg']
    return f"""struct {{
        {'\n'.join(argument(arg, namespace) for arg in args)}
    }}"""

def enumEntry(element: ET.Element, namespace) -> str:
    name = rename(element.attrib['name'], namespace)
    value = element.attrib['value']
    return f"{name} = {value},"

def bitfield(element: ET.Element, namespace) -> str:
    entries = [child for child in element if child.tag == 'entry']
    entries.sort(key = lambda e: int(e.attrib['value'], 0))
    lines = []
    prev = 0.5
    for e in entries:
        value = int(e.attrib['value'], 0)
        if not value:
            continue
        # These fields are combination fields and are stupid
        if 2 ** int(log2(value)) != value:
            continue
        padding = int(log2(value / prev)) - 1
        if padding:
            lines.append(f'_: u{padding},')
        name = rename(e.attrib['name'], namespace)
        lines.append(f'{name}: bool,')
        prev = value
    padding = 32 - int(log2(prev)) - 1
    if padding:
        lines.append(f'_: u{padding},')
    return f"""packed struct(u32) {{
        {'\n'.join(lines)}
        comptime {{
            if (@bitSizeOf(@This()) != 32)
                @compileError("Invalid Bitfield in Protocol");
        }}
    }}"""

def enum(element: ET.Element, namespace: str) -> str:
    if 'bitfield' in element.attrib and element.attrib['bitfield'] == "true":
        return bitfield(element, namespace);
    entries = [child for child in element if child.tag == 'entry']
    return f"""enum(u32) {{
        {'\n'.join(enumEntry(e, namespace) for e in entries)}
    }}"""

def interface(element: ET.Element, namespace: str) -> str:
    name = element.attrib['name']
    if not name.startswith(f'{namespace}_'):
        raise Exception("interface does not start with namespace")
    name = name.removeprefix(f'{namespace}_')

    requests = [
        child
        for child in element
        if child.tag == 'request'
    ]
    events = [
        child
        for child in element
        if child.tag == 'event'
    ]
    enums = [
        child
        for child in element
        if child.tag == 'enum'
    ]
    return f"""
        pub const {name} = struct {{
            pub const request = enum {{
                {'\n'.join(
                    f'{rename(r.attrib['name'], namespace)},'
                    for r in requests
                )}
            }};

            pub const event = enum {{
                {'\n'.join(
                    f'{rename(e.attrib['name'], namespace)},'
                    for e in events
                )}
            }};

            pub const rq = union(request) {{
                { '\n'.join(
                    f'{
                        rename(r.attrib['name'], namespace)
                    }: {
                        method(r, namespace)
                    },'
                    for r in requests
                ) }
            }};

            pub const ev = struct {{
                { '\n'.join(
                    f'pub const {
                        rename(e.attrib['name'], namespace)
                    } = {
                        method(e, namespace)
                    };'
                    for e in events
                ) }
            }};

            { '\n'.join(
                f'pub const {
                    initCaps(rename(e.attrib['name'], namespace))
                } = {
                    enum(e, namespace)
                };'
                for e in enums
            ) }
        }};
    """

def protocol(root: ET.Element):
    if root.tag != 'protocol':
        raise Exception("root is not a protocol")

    name = root.attrib['name']

    namespace = commonPrefix([
        child.attrib['name']
        for child in root
        if child.tag == 'interface'
    ]).split('_')[0]

    if not namespace:
        print(f"Warning: protocol '{name}' has no namespace")

    try:
        cprt = next(
            child.text for child in root
            if child.tag == 'copyright' and child.text is not None
        )
    except StopIteration:
        cprt = ''
    else:
        cprt = '\n'.join(f'// {line}' for line in cprt.split('\n'))

    interfaces = [
        interface(child, namespace)
        for child in root
        if child.tag == 'interface' and
            child.attrib['name'] not in deprecated
    ]

    return f"""
        {cprt}

        const types = @import("types.zig");

        {'\n'.join(interfaces)}
    """, namespace

class Enum:
    def __init__(self, element: ET.Element, namespace) -> None:
        self.entries = [
            (rename(child.attrib['name'], namespace), child.attrib['value'])
            for child in element if child.tag == 'entry'
        ]

    def output(self) -> str:
        return f"""enum(u32) {{
            {'\n'.join(f'{name} = {value},' for name, value in self.entries)}
        }}"""

class BitField(Enum):
    def __init__(self, element: ET.Element, namespace):
        entries = [child for child in element if child.tag == 'entry']
        entries.sort(key = lambda e: int(e.attrib['value'], 0))
        self.entries = [
            (
                rename(e.attrib['name'], namespace),
                int(e.attrib['value'], 0)
            )
            for e in entries
        ]
        self.entries = [
            (name, value) for name, value in self.entries
            if value and 2 ** int(log2(value)) == value
        ]
    def output(self) -> str:
        lines = []
        prev = 0.5
        for name, value in self.entries:
            if not value:
                continue
            # These fields are combination fields and are stupid
            if 2 ** int(log2(value)) != value:
                continue
            padding = int(log2(value / prev)) - 1
            if padding:
                lines.append(f'_: u{padding},')
            name = rename(e.attrib['name'], namespace)
            lines.append(f'{name}: bool,')
            prev = value
        padding = 32 - int(log2(prev)) - 1
        if padding:
            lines.append(f'_: u{padding},')
        return f"""packed struct(u32) {{
            {'\n'.join(lines)}
            comptime {{
                if (@bitSizeOf(@This()) != 32)
                    @compileError("Invalid Bitfield in Protocol");
            }}
        }}"""

class Interface:
    def __init__(self, element: ET.Element, namespace):
        if not element.attrib['name'].startswith(f'{namespace}_'):
            raise Exception("interface does not start with namespace")
        self.name = element.attrib['name'].removeprefix(f'{namespace}_')
        self.namespace = namespace

        self.requests = [
            child
            for child in element
            if child.tag == 'request'
        ]
        self.events = [
            child
            for child in element
            if child.tag == 'event'
        ]
        self.enums = [
            child
            for child in element
            if child.tag == 'enum'
        ]

    def output(self) -> str:
        return f"""
            pub const {self.name} = struct {{
                pub const request = enum {{
                    {'\n'.join(
                        f'{rename(r.attrib['name'], self.namespace)},'
                        for r in self.requests
                    )}
                }};

                pub const event = enum {{
                    {'\n'.join(
                        f'{rename(e.attrib['name'], self.namespace)},'
                        for e in self.events
                    )}
                }};

                pub const rq = union(request) {{
                    { '\n'.join(
                        f'{
                            rename(r.attrib['name'], self.namespace)
                        }: {
                            method(r, self.namespace)
                        },'
                        for r in self.requests
                    ) }
                }};

                pub const ev = struct {{
                    { '\n'.join(
                        f'pub const {
                            rename(e.attrib['name'], self.namespace)
                        } = {
                            method(e, self.namespace)
                        };'
                        for e in self.events
                    ) }
                }};

                { '\n'.join(
                    f'pub const {
                        initCaps(rename(e.attrib['name'], self.namespace))
                    } = {
                        enum(e, self.namespace)
                    };'
                    for e in self.enums
                ) }
            }};
        """

class Protocol:
    def __init__(self, root: ET.Element):
        self.imports = ["types"]
        self.root = root

        if root.tag != 'protocol':
            raise Exception("root is not a protocol")

        name = root.attrib['name']

        namespace = commonPrefix([
            child.attrib['name']
            for child in root
            if child.tag == 'interface'
        ]).split('_')[0]

        if not namespace:
            print(f"Warning: protocol '{name}' has no namespace")

        self.load_copyright()

    def load_copyright(self):
        try:
            copyright_notice = next(
                child.text for child in self.root
                if child.tag == 'copyright' and child.text is not None
            )
        except StopIteration:
            self.copyright_notice = ''
        else:
            self.copyright_notice = '\n'.join(f'// {line}' for line in copyright_notice.split('\n'))

    def output(self) -> str:
        interfaces = [
            interface(child, namespace)
            for child in root
            if child.tag == 'interface' and
                child.attrib['name'] not in deprecated
        ]

        imports = '\n'.join(f'const types = @import("{i}.zig")' for i in self.imports)

        return f"""
            {cprt}

            const types = @import("types.zig");

            {'\n'.join(interfaces)}
        """, namespace

def find_protocols(search: Path) -> list[Path]:
    core = list(search.glob("wayland.xml"))
    stable = list(search.glob("stable/**/*.xml"))
    staging = list(search.glob("staging/**/*.xml"))
    unstable = list(search.glob("unstable/**/*.xml"))
    # filter out stable protocols
    def hasStableVersion(f: Path) -> bool:
        unneeded = lambda part: match('^(unstable)|(v[0-9]+)$', part)
        filtername = lambda name: '-'.join(part for part in name.split('-') if not unneeded(part))
        return filtername(f.stem) in (filtername(s.stem) for s in stable)
    unstable = [f for f in unstable if not hasStableVersion(f)]
    return core + stable + unstable + staging

def handler(f, n, i, t) -> str:
    name = i.removeprefix(f'{n}_') if n else i
    tp = f'{f}.{name}.{t}'
    return f'std.EnumArray({tp}, ?struct {{ context: *anyopaque, call: *const fn (*anyopaque, u32, {tp}, []const u8) void, }},),'

def main(output, args):
    files = [p for path in args for p in find_protocols(Path(path))]

    destination = Path(output)
    destination.mkdir(parents=True, exist_ok=True)

    interfaces = []

    for file in files:
        tree = ET.parse(file)

        root = tree.getroot()
        try:
            proto, namespace = protocol(root)
        except Exception as e:
            print(f"Error: Invalid wayland file - {e}")
            continue

        output = destination / f"{root.attrib['name']}.zig"
        with open(output, 'w') as f:
            f.write(zigFormat(proto))

        interfaces += [
            (root.attrib['name'], namespace, i.attrib['name'])
            for i in root
            if i.tag == 'interface' and
                i.attrib['name'] not in deprecated
        ]

    fnptr = '?struct { context: *anyopaque, call: *const fn (*anyopaque, u32, enum {}, []const u8) void, },'
    types = destination / 'types.zig'
    index = destination / 'proto.zig'
    with types.open('w') as f:
        f.write(zigFormat(definitions));
    # ```    wl_display: std.EnumArray(wayland.display.event, *const fn (u32) void),```
    with index.open('w') as f:
        f.write(zigFormat(f"""
            const std = @import("std");

            { '\n'.join(
                f'pub const {f} = @import("{f}.zig");'
                for f in { f for f, _, _ in interfaces }
            ) }

            pub const types = @import("types.zig");

            pub const Interface = enum {{
                invalid,
                { '\n'.join(f'{i},' for _, _, i in interfaces) }
            }};

            pub const map = std.EnumArray(Interface, type).init(.{{
                .invalid = enum {{}},
                { '\n'.join(
                    f'.{i} = {f}.{i.removeprefix(f'{n}_') if n else i}.event,'
                    for f, n, i in interfaces)
                }
            }});

            pub const Events = union(Interface) {{
                invalid: std.EnumArray(enum {{}}, {fnptr}),
                { '\n'.join(
                    f'{i}: {handler(f, n, i, 'event')}'
                    for f, n, i in interfaces
                ) }
            }};
        """))

if __name__ == "__main__":
    main(argv[1], argv[2:])
