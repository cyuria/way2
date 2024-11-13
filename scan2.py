#!/usr/bin/env python3

""" Scan2
A python script to enumerate wayland protocol requests and events as zig source
code.
"""

from itertools import groupby
from math import log2
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
    "wl_shell", "wl_shell_surface",
]

disallowed_words = {
    "addrspace",   "align",          "allowzero",   "and",
    "anyframe",    "anytype",        "asm",         "async",
    "await",       "break",          "callconv",    "catch",
    "comptime",    "const",          "continue",    "defer",
    "else",        "enum",           "errdefer",    "error",
    "export",      "extern",         "fn",          "for",
    "if",          "inline",         "linksection", "noalias",
    "noinline",    "nosuspend",      "opaque",      "or",
    "orelse",      "packed",         "pub",         "resume",
    "return",      "struct",         "suspend",     "switch",
    "test",        "threadlocal",    "try",         "union",
    "unreachable", "usingnamespace", "var",         "volatile",
    "while",
}.union({
    "isize",    "usize",      "c_char",      "c_short",
    "c_ushort", "c_int",      "c_uint",      "c_long",
    "c_ulong",  "c_longlong", "c_ulonglong", "c_longdouble",
    "f16",      "f32",        "f64",         "f80",
    "f128",     "bool",       "anyopaque",   "void",
    "noreturn", "type",       "anyerror",    "comptime_int",
    "comptime_float",
}).union({
    "std",  "types", "true", "false",
    "null", "undefined",
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
    if next(tree.iter('interface'), None) is None:
        return ''

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

def renameEnum(name: str) -> str:
    return ''.join(word.title() for word in name.split('_'))

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
        ) }
    }};
    """

def genProtoZig(protocols: Iterable[xml.ElementTree]) -> str:
    return zigFormat(f"""
        pub const std = @import("std");

        {genImportAll(protocols)}

        pub const types = @import("types.zig");

        {genInterfaceEnum(protocols)}
        {genMap(protocols)}
        {genEvents(protocols)}
    """)

def genTypesZig() -> str:
    return zigFormat(f"""
        pub const String = []const u8;
        pub const Array = []const u32;
    """)

def findEnumDefinition(
    definition: str,
    current_interface: xml.Element,
    current_tree: xml.ElementTree
) -> tuple[xml.ElementTree | None, xml.Element | None, xml.Element]:
    try:
        if '.' not in definition:
            return next(
                (None, None, enum)
                for enum in current_interface.iter('enum')
                if enum.attrib['name'] == definition
            )

        interface_name, enum_name = definition.split('.')
        try:
            return next(
                (None, interface, enum)
                for interface in current_tree.iter('interface')
                if interface.attrib['name'] == interface_name
                for enum in interface.iter('enum')
                if enum.attrib['name'] == enum_name
            )
        except StopIteration:
            return next(
                (tree, interface, enum)
                for tree in trees
                for interface in tree.iter('interface')
                if interface.attrib['name'] == interface_name
                for enum in interface.iter('enum')
                if enum.attrib['name'] == enum_name
            )
    except StopIteration:
        print(f"scan2.py: fatal: Unable to find definition for {definition}", file=stderr)
        exit(1)

def genSingleArgument(argument: xml.Element, interface: xml.Element, tree: xml.ElementTree) -> str:
    if argument.attrib['type'] == "fd":
        return ''

    if argument.attrib['type'] == "uint" and 'enum' in argument.attrib:
        enum_tree, enum_interface, enum = findEnumDefinition(argument.attrib['enum'], interface, tree)
        tree_decl = f'@import("{enum_tree.getroot().attrib['name']}.zig").' if enum_tree is not None else ''
        interface_decl = f'{rename(enum_interface, enum_tree or tree)}.' if enum_interface is not None else ''
        return f"{rename(argument, tree)}: {tree_decl}{interface_decl}{renameEnum(enum.attrib['name'])},"

    if argument.attrib['type'] == "new_id" and "interface" not in argument.attrib:
        return f"""
            interface: {type_mapping['string']},
            version: {type_mapping['uint']},
            {rename(argument, tree)}: {type_mapping[argument.attrib['type']]},
        """

    return f"{rename(argument, tree)}: {type_mapping[argument.attrib['type']]},"

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

def genSingleBitfield(bitfield: xml.Element, tree: xml.ElementTree) -> str:
    return f"""
        pub const {renameEnum(bitfield.attrib['name'])} = packed struct(u32) {{
            { '\n'.join(
                f'{name}: bool,' if name != '_' else f'_: u{sum(1 for _ in group)},'
                for name, group in groupby(next((
                    rename(entry, tree)
                    for entry in bitfield.iter('entry')
                    if int(entry.attrib['value'], 0) > 0 and
                        log2(int(entry.attrib['value'], 0)) == i
                ), '_') for i in range(32))
            ) }
        }};
    """

def genSingleEnum(enum: xml.Element, tree: xml.ElementTree) -> str:
    if 'bitfield' in enum.attrib and enum.attrib['bitfield'] == 'true':
        return genSingleBitfield(enum, tree)
    return f"""
        pub const {renameEnum(enum.attrib['name'])} = enum (u32) {{
            { '\n'.join(
                f'{rename(entry, tree)} = {entry.attrib['value']},'
                for entry in enum.iter('entry')
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

            { '\n'.join(
                genSingleEnum(enum, tree)
                for enum in interface.iter('enum')
            ) }
        }};
    """

def genSingleZig(tree: xml.ElementTree) -> str:
    return zigFormat(f"""
        { '\n'.join(
            f'// {line.strip()}'.strip()
            for e in tree.iter('copyright') if e.text
            for line in e.text.split('\n')
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
    trees = [tree for tree in trees if tree.getroot().tag == 'protocol']

    with open(destination / 'types.zig', 'w') as f:
        f.write(genTypesZig())
    with open(destination / 'proto.zig', 'w') as f:
        f.write(genProtoZig(trees))

    for tree in trees:
        with open(destination / f'{tree.getroot().attrib['name']}.zig', 'w') as f:
            f.write(genSingleZig(tree))

if __name__ == "__main__":
    main(argv[1], argv[2:])
