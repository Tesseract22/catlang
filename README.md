# Catlang
A language mainly to educate myself about compiler construction and optimization. For this purpose and in the spirit of recreational programming, I purposefully overcomplicate and oversimplify some parts of the compiler design, so as to make it easier for to explore:

* Interning of types and other compile time objects,
* And other more or less data-oriented approach
* A platform-independent IR (intermediate representation), which is then translated to platform-dependent assembly,
* With a linear register allocation alogrithms, and simple instruction selection & instruction scheduling

Catlang is statically typed, manual-memory-managed.

Catlang's compiler is currently written in `Zig`, and aims to be self-hosted in the future.
The compiler currrently is able to produce x86-64 GNU assembly.
## Roadmap to v0.1.0

### Backend
- [x] Compilation for X86-64 windows
- [ ] Compilation for ARM64 linux/windows
- [x] Foreign procedure call (C ABI)
- [ ] External variable
      
### Frontend

- [ ] Enum
- [ ] newtype



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
### Struct
Struct is wrapped in curly braces, where each field starts with a `.` and a name, followed by `=`, and then the value.
```rust
proc main() {
    let student := {.name = "Bob", .age = 15, .height = 1.75};
    print(student.name);
    print(student.age);
    print(student.height);
}
```
The type of a struct can be expressed in a similar fasion:
```rust
fn new_year(student: {.name: *char, .age: int, .height: float}): {.name: *char, .age: int, .height: float} {
    ret {.name = "Tom", .age = student.age + 1, .height = student.height};
}
```

### Tuple
Tuple is basically unnamed struct:
```rust
let tuple := {1, 3.14, "hello world", {2, [1, 2, 3]}};
print(tuple[0]);
print(tuple[1]);
print(tuple[2]);
print(tuple[3][0]);

print(tuple[3][1][0]);
print(tuple[3][1][1]);
print(tuple[3][1][2]);
```
The field of tuple can be accessed by a number. It can not be accessed by any other expression (e.g. `tuple[1+2]` or `tuple[foo()]` would not compile).

The type of a tuple can be expressed in a similar fasion:
```rust
proc foo(tuple: {int, float, *char, {int, [3]int}}) {
    ...
}
```
### Type Alias
A type expression can be defined with the following syntax:
```Rust
type IDEN: [type_expression]
```
```Rust
type Student: {.name: *char, .age: int, .height: float};
type Person: Student;
proc main() {
    let student := {.name = "Bob", .age = 15, .height = 1.75};
    foo(student);

    let new_student := new_year(student);
    foo(new_student);
}

proc foo(student: Student) {
    print(student.name);
    print(student.age);
    print(student.height);

}

fn new_year(person: Person): Person {
    ret {.name = person.name, .age = person.age + 1, .height = person.height};
}
```
From the compiler's point of view, `Student` is completely identical to `{.name: *char, .age: int, .height: float}`, which is also completely identical to `Person`

### C Interop
A foreign function can be declared as follow:
```Rust
foreign "InitWindow": (int, int, *char) -> void;
```
Here is a full example of drawing a bouncing square with `raylib`'s C API.
```Rust
foreign "InitWindow": (int, int, *char) -> void;
foreign "WindowShouldClose": () -> bool;
foreign "BeginDrawing": () -> void;
foreign "EndDrawing": () -> void;
type Color: [4]char;
foreign "DrawRectangle": (int, int, int, int, Color) -> void;
foreign "ClearBackground": (Color) -> void;
foreign "GetFrameTime": () -> float;
proc main() {
    let width := 800;
    let height := 600;
    let sq_size := 100;
    let bg_color :Color = [32, 32, 32, 255];
    let sq_color :Color = [255, 0, 0, 255];
    InitWindow(width, height, "Hello From Catlang");
    let v :[2]float = [200.0, 200.0];
    let pos := [(width/2-sq_size/2) as float, (height/2-sq_size/2) as float];
    loop !WindowShouldClose() {
	let dt := GetFrameTime();
	BeginDrawing();
	ClearBackground(bg_color);
	DrawRectangle(pos[0] as int, pos[1] as int, sq_size, sq_size, sq_color);
	if pos[0] < 0.0 {
	    v[0] = 0.0-v[0];
	    pos[0] = 0.0;
	}
	if pos[0] + sq_size as float > width as float {
	    v[0] = 0.0-v[0];
	    pos[0] = (width - sq_size) as float;
	}
	if pos[1] < 0.0 {
	    v[1] = 0.0-v[1];
	    pos[1] = 0.0;
	}
	if pos[1] + sq_size as float > height as float {
	    v[1] = 0.0-v[1];
	    pos[1] = (height - sq_size) as float;
	}
	pos[0] = pos[0] + dt * v[0];
	pos[1] = pos[1] + dt * v[1];
	

	EndDrawing();

    }
}
```
