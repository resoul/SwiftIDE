import CLib
import ObjCLib

let total = clib_add(2, 3)
let length = clib_length(clib_point(x: 3, y: 4))
let greeter = ObjCGreeter(name: "world")

print(total, length, greeter.greeting(forTimes: 2))
