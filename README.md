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

## Comprehensive Syntaxes
### function
There is two type of "function" in catlang, `fn` and `proc` (idea stolen from `Ada`). `proc` is basically `fn` without `void` return type.
```rust
proc main() {
    foo();
    print(bar(12));

}

proc foo() {
    print("hello world");
    print(69);
}

fn bar(x: int): int {
    ret x * x;
}
```
### if
```rust
proc whatday(x: int) {
    if x == 1 {
        print("Monday");
    } else if x == 2 {
        print("Tuesday");
    } else if x == 3 {
        print("Wednesday");
    } else if x == 4 {
        print("Thursday");
    } else if x == 5 {
        print("Friday");
    } else if x == 6 {
        print("Saturday");
    } else if x == 7 {
        print("Sunday");
    } else {
        print("Not a day!");
    }
}

```
### loop
```rust
proc main() {
    let x := 1;
    loop x < 8{
        whatday(x);
        x = x + 1;
    }
}
```
The condition in the loop can be omitted to create unconditional loop.

### Pointer
Unlike in `C`, the `dereference` and `addressof` are postfix operators.
```rust
proc main() {
    let x := 5;
    let ref := x.&;

    ref.* = 10;

    print(ref);
    print(x);

    let ref_ref := ref.&;
    print(ref_ref);

    let y := 69;
    ref_ref.* = y.&;

    print(ref.*);

    let sum := ref.* + ref_ref.*.*;
    print(sum);
}
```

### Casting
```rust
proc main() {
    let x := 5 as float;
    let y := x * 10.0;
    print(y);

    let z := (y / 15.0) as int;
    print(z);

    let ello := ("hello world" as int + 1) as *char;
    print(ello);
}
```
C-style bitcast:
```rust
proc main() {
    let x := 3.1415926;
    let cast_x := (x.& as *int).*;
    print(cast_x);
}
```
