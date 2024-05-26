# Catlang (temporary name)
A research language mainly to educate myself about compiler construction and optimization.
Calang's compiler is currently written in `Zig`, and aims to be self-hosted in the future.

Catlang can be compiled to x86-64 nasm.

## Basic Syntax
```rust
proc main() {
    let x := 10;
    let y := x / 2;
    print(f(5, x) + f(4, y));
}
fn f(i: int, j: int): int {
    ret i * j;
}
```

## Install
`zig build` to build the compiler

`zig-out/bin/lang -c <src> -o <out>` to compile a given `.cat` file.

`zig build compile` to compile all the examples in `lang` folder.

