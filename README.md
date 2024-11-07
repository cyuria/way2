# Way2

Way2 is a zig only wayland client with support for multiple shell protocols and
powerful pixel drawing features.

## Using

Run the following command to add way2 as a package.

```sh
zig fetch --save git+https://github.com/cyuria/way2
```

The available modules are:
- `way2` for the wayland client
- `type2` for the underlying types used by all the modules
- `draw2` for pixel drawing

### Requirements

- The zig compiler (from master, i.e. at least v0.14.0)
- Python (at least version 3.9)

## Examples

There is one example currently available. It can be compiled and run with
```sh
zig build run
```

It is the default target for `zig build` as well.
