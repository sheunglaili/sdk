// Copyright (c) 2017, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

class A {}

class B extends A {}

class C {
  Object operator [](B b) => 0;
}

void main() {
  A a = new B();
  C c = new C();
  c[a];
  //^
  // [analyzer] COMPILE_TIME_ERROR.ARGUMENT_TYPE_NOT_ASSIGNABLE
  // [cfe] A value of type 'A' can't be assigned to a variable of type 'B'.
}
