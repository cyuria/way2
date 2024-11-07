# Contributing

If you've found this project and want to contribute, please do.

You can:
-   Open or comment on an issue
-   Fork the repository and open a pull request
-   Anything else

The rest of this document is effectively a braindump of design decisions made
in the codebase.

More stuff can be found under the [`docs/`](docs/) directory.

## Design Decisions

This project will do its best to adhere to unix philosophy. Unfortunately, by
nature, it already breaks unix philosophy somewhat. Hopefully however, the code
itself is properly structured that any one individual file can be clearly
understood by itself.

### Wayland Only

For the foreseeable future, way2 will only support wayland. Why? Because I said
so.

That being said, if someone can replace all the functionality of `way2.zig`
with something like `xorg2.zig`, then way2 can become just as viable on X11 as
well.

The same goes for supporting other platforms and operating systems. Currently
only x86_64 linux is supported, however if someone wants to ensure freeBSD
support, they are welcome to do so. Support for other CPU architectures, as
well as Windows and MacOS is similarly unplanned but welcome.

Windows might be hard due to the lack of proper unix socket support, but I
believe there are workarounds which exist.

### Performance

Way2 does not need to be blazingly fast. It should however be simple enough
that the code can simply get out of the way and never have performance issues.
This means features like hardware acceleration will likely never be
implemented.

One of the motivating factors for way2 is power efficiency. That basically
eliminates hardware acceleration from the equation.

Hardware acceleration is also typically less versatile than a software rendered
alternative, which can make code more complicated than strictly necessary.

### Dependencies

There should be exactly zero hard runtime dependencies. That means, as long as
you have a POSIX compliant system, way2 should be perfectly functional. In
practice, this won't be true. Also by nature it requires a wayland compositor
of some kind.

Soft runtime dependencies include stuff like a wlroots compositor, where a user
can *optionally* use protocols like `wlr_layer_shell` to open windows instead
of the default `xdg_shell`.

### Out of Memory

Noone can agree on how to correctly handle OOM conditions. For the sake of ease
of development, here they will all be handled with a panic as follows:

```zig
allocator.alloc(size) catch @panic("Out of memory");
```

### Type2 - Gluing Everything Together

Type2 provides a few simple definitions for unifying different modules and is
the *only* dependency of every other single file module.

Type2 simply provides a consistent interface for all the other modules to
correctly work with each other, and nothing more.

Type2 should never contain runtime code.

### Way2 - The Custom Wayland Client

Way2 is a single file[^1] wayland window client. Like the other modules, way2
exposes an API that is intended for both ease of use in simple scenarios, while
providing enough control to the developer to have enough customisability for
most usecases.

For now, way2 only supports pixel buffer drawing on the CPU side. This is
because it is easier to do and works seamlessly with the other modules.

Support for hardware accelerated rendering may be considered in the future.

Way2 provides code which can manage the creation, deleting, etc of windows, as
well as the event handling that comes with window management.

Way2 should provide all the code required for opening a window, resizing it,
handling events, etc and nothing more.

Currently, all wayland events are handled via a table of pointers, assigned at
runtime. This means wayland events may have a noticeable performance cost. It
may be beneficial to also provide a static, comptime table for some events,
such as registry globals.

[^1]: There is also `scanner.py` and the protocols which are generated during
      the build process.

### Draw2 - Shape Drawing

Draw2 is intended to be a highly extensible single file, generic shape drawing
module. Like the rest of the single file modules, it can work on any surfaces
or pixel buffers supported by the basic types defined in `type2.zig`.

Under the hood, draw2 uses a system inspired by the standard 3D graphics
pipeline. Effectively there are two independent pieces of code. One is
responsible for generating a large buffer of pixels. The other is responsible
for determining the colour of a single pixel. This is reminicent of the vertex
shader and fragment shader pipeline in 3D graphics.

Draw2 is intended for these programs to be composable by advanced users.

Draw2 provides a variety of "default" common options, to simplify the process
of rendering common combinations of "generators" and "shaders" for popular use
cases. These "default" options are intended for use in materials like beginners
tutorials.

### Font2 - Rendering Fonts

Font2 has not yet been started. The plan is to create an in house font
rasteriser in pure zig.

### Image2 - Loading Rasterised Images

Image2 has not yet been started. The plan is to create an in house image loader
in pure zig.

### Graphic2 - Rendering Vector Images

Graphic2 has not yet been started. The plan is to create an in house vector
image loader and renderer for images such as SVGs.

### Inspirations

One of the greatest sources of inspiration for this project's GUI modules is
the pygame project. It accomplishes almost the exact goals of this project,
with a minor exception being that pygame is targeted at gamedev in python, and
is cross-platform, whereas the GUI modules are intended more for general GUI
development, when the ability to set individual pixels is preferable over a
series of dynamic widget rendering tools like you get with toolkits like GTK
and QT.
