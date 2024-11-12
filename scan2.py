#!/usr/bin/env python3

""" Scan2
A python script to enumerate wayland protocol requests and events as zig source
code.
"""

from pathlib import Path
from re import match
from subprocess import check_output
from sys import argv, stderr
from typing import Iterable
from xml.etree import ElementTree as xml

trees: Iterable[xml.ElementTree] = []

type_mapping = {
    "array": "types.Array",
    "int": "i32",
    "fixed": "f64",
    "new_id": "u32",
    "object": "u32",
    "string": "types.String",
    "uint": "u32",
}

deprecated_interfaces = [
    "wl_shell",
    "wl_shell_surface",
]

disallowed_words = {
    "addrspace",
    "align",
    "allowzero",
    "and",
    "anyframe",
    "anytype",
    "asm",
    "async",
    "await",
    "break",
    "callconv",
    "catch",
    "comptime",
    "const",
    "continue",
    "defer",
    "else",
    "enum",
    "errdefer",
    "error",
    "export",
    "extern",
    "fn",
    "for",
    "if",
    "inline",
    "linksection",
    "noalias",
    "noinline",
    "nosuspend",
    "opaque",
    "or",
    "orelse",
    "packed",
    "pub",
    "resume",
    "return",
    "struct",
    "suspend",
    "switch",
    "test",
    "threadlocal",
    "try",
    "union",
    "unreachable",
    "usingnamespace",
    "var",
    "volatile",
    "while",
}.union({
    "isize",
    "usize",
    "c_char",
    "c_short",
    "c_ushort",
    "c_int",
    "c_uint",
    "c_long",
    "c_ulong",
    "c_longlong",
    "c_ulonglong",
    "c_longdouble",
    "f16",
    "f32",
    "f64",
    "f80",
    "f128",
    "bool",
    "anyopaque",
    "void",
    "noreturn",
    "type",
    "anyerror",
    "comptime_int",
    "comptime_float",
}).union({
    "std",
    "types",
    "true",
    "false",
    "null",
    "undefined",
})

def isAllowed(word: str) -> bool:
    if word in disallowed_words:
        return False
    if match('^[iu][0-9]+$', word):
        return False
    if match('^[^a-zA-Z]', word):
        return False
    return True

def getNamespace(tree: xml.ElementTree) -> str:
    try:
        next(tree.iter('interface'))
    except StopIteration:
        return ""

    for i, letters in enumerate(zip(*(i.attrib['name'] for i in tree.iter('interface')))):
        if len(set(letters)) > 1:
            return next(tree.iter('interface')).attrib['name'][:i].split('_')[0]
    return min(tree.iter('interface'), key=lambda i: len(i.attrib['name'])).attrib['name'].split('_')[0]

def getEvent(interface: xml.Element, tree: xml.ElementTree) -> str:
    file = tree.getroot().attrib['name']
    return f'{file}.{rename(interface, tree)}.event'

def rename(element: xml.Element, tree: xml.ElementTree) -> str:
    cut = element.attrib['name'].removeprefix(f'{getNamespace(tree)}_')
    if not isAllowed(cut):
        return f'{getNamespace(tree)}_{cut}'
    return cut

def zigFormat(source: str) -> str:
    return check_output(['zig', 'fmt', '--stdin'], input=source, text=True)

def genImportAll(tree: Iterable[xml.ElementTree]) -> str:
    return '\n'.join(
        f'pub const {protocol.attrib['name']} = @import("{protocol.attrib['name']}.zig");'
        for tree in tree
        for protocol in tree.iter('protocol')
    )

def genInterfaceEnum(trees: Iterable[xml.ElementTree]) -> str:
    return zigFormat(f"""pub const Interface = enum {{
        invalid,
        { '\n'.join(
            f'{interface.attrib['name']},'
            for tree in trees
            for interface in tree.iter('interface')
            if tree.getroot().tag == 'protocol'
        ) }
    }};""")

def genMap(trees: Iterable[xml.ElementTree]) -> str:
    return f"""
    pub const map = std.EnumArray(Interface, type).init(.{{
        .invalid = enum {{}},
        { '\n'.join(
            f'.{interface.attrib['name']} = {getEvent(interface, tree)},'
            for tree in trees
            for interface in tree.iter('interface')
            if tree.getroot().tag == 'protocol'
        ) }
    }});
    """

def genEvents(trees: Iterable[xml.ElementTree]) -> str:
    return f"""
    pub const Events = union(Interface) {{
        invalid: std.EnumArray(enum {{}}, ?struct {{ context: *anyopaque, call: *const fn (*anyopaque, u32, enum {{}}, []const u8) void, }},),
        { '\n'.join(
            f"""{interface.attrib['name']}: std.EnumArray(
                {getEvent(interface, tree)},
                ?struct {{
                    context: *anyopaque,
                    call: *const fn (*anyopaque, u32, {getEvent(interface, tree)}, []const u8) void,
                }},
            ),"""
            for tree in trees
            for interface in tree.iter('interface')
            if tree.getroot().tag == 'protocol'
        ) }
    }};
    """

def genProtoZig(protocols: Iterable[xml.ElementTree]) -> str:
    return zigFormat(f"""
        pub const std = @import("std");

        {genImportAll(protocols)}
        {genInterfaceEnum(protocols)}
        {genMap(protocols)}
        {genEvents(protocols)}
    """)

def genTypesZig() -> str:
    return zigFormat(f"""
        pub const String = []const u8;
        pub const Array = []const u32;
    """)

def findEnumDefinition(definition: str, interface: xml.Element) -> tuple[xml.ElementTree | None, xml.Element, xml.Element]:
    if len(definition.split('.')) > 1:
        try:
            tree, interface = next(
                (tree, interface)
                for tree in trees
                if tree.getroot().tag == 'protocol'
                for interface in tree.iter('interface')
                if interface.attrib['name'] == definition.split('.')[-2]
            )
        except StopIteration:
            print(f"scan2.py: fatal: Unable to find definition for {definition}", file=stderr)
            exit(1)
    else:
        tree, interface = None, interface

    try:
        return tree, interface, next(
            enum for enum in interface.iter('enum')
            if enum.attrib['name'] == definition.split('.')[-1]
        )
    except StopIteration:
        print(f"scan2.py: fatal: Unable to find definition for {definition}", file=stderr)
        exit(1)

def genSingleArgument(argument: xml.Element, interface: xml.Element, tree: xml.ElementTree) -> str:
    name = rename(argument, tree)
    tp = argument.attrib['type']
    if tp == "fd":
        return ''
    if tp == "uint" and 'enum' in argument.attrib:
        enum_tree, interface, enum = findEnumDefinition(argument.attrib['enum'], interface)
        fetch = f'@import({enum_tree.getroot().attrib['name']}.zig)' if enum_tree else ''
        return f"{name}: {fetch}.{rename(interface, enum_tree or tree)}.{rename(enum, enum_tree or tree)},"
    if tp == "new_id" and "interface" not in argument.attrib:
        return f"""
            interface: {type_mapping['string']},
            version: {type_mapping['uint']},
            {name}: {type_mapping[tp]},
        """
    return f"{name}: {type_mapping[tp]},"

def genSingleRequest(request: xml.Element, interface: xml.Element, tree: xml.ElementTree) -> str:
    return f"""
        {rename(request, tree)}: struct {{
            { '\n'.join(
                genSingleArgument(argument, interface, tree)
                for argument in request.iter('arg')
            ) }
        }},
    """

def genSingleEvent(event: xml.Element, interface: xml.Element, tree: xml.ElementTree) -> str:
    return f"""
        pub const {rename(event, tree)} = struct {{
            { '\n'.join(
                genSingleArgument(argument, interface, tree)
                for argument in event.iter('arg')
            ) }
        }};
    """

def genSingleInterface(interface: xml.Element, tree: xml.ElementTree) -> str:
    return f"""
        pub const {rename(interface, tree)} = struct {{
            pub const request = enum {{
                {'\n'.join(
                    f'{rename(request, tree)},'
                    for request in interface.iter('request')
                )}
            }};

            pub const event = enum {{
                {'\n'.join(
                    f'{rename(event, tree)},'
                    for event in interface.iter('event')
                )}
            }};

            pub const rq = union(request) {{
                { '\n'.join(
                    genSingleRequest(request, interface, tree)
                    for request in interface.iter('request')
                ) }
            }};

            pub const ev = struct {{
                { '\n'.join(
                    genSingleEvent(event, interface, tree)
                    for event in interface.iter('event')
                ) }
            }};
        }};
    """
    #{{ '\n'.join(
    #    f'pub const {{
    #        initCaps(rename(e.attrib['name'], namespace))
    #    }} = {{
    #        enum(e, namespace)
    #    }};'
    #    for e in element.iter('enum')
    #) }}

def genSingleZig(tree: xml.ElementTree) -> str:
    return zigFormat(f"""
        { '\n'.join(
            f'// {line.strip()}'.strip()
            for e in tree.iter('copyright')
            if e.text
            for line in (*e.text.split('\n'), '')
        ) }

        const types = @import("types.zig");

        { '\n'.join(
            genSingleInterface(interface, tree)
            for interface in tree.iter('interface')
        ) }
    """)

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

def main(output, args):
    files = [p for path in args for p in find_protocols(Path(path))]

    destination = Path(output)
    destination.mkdir(parents=True, exist_ok=True)

    global trees
    trees = [xml.parse(file) for file in files]

    #with open(destination / 'proto.zig') as f:
    #f.write(
    #print(genProtoZig(trees))
    #)

    for tree in trees:
        print(genSingleZig(tree))

    """
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
        f.write(zigFormat(f"" "
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
        " ""))

    """

if __name__ == "__main__":
    main(argv[1], argv[2:])
