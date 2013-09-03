// Copyright (c) 2013, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:async_helper/async_helper.dart';
import "package:expect/expect.dart";
import 'dart:async';
import 'catch_errors.dart';

main() {
  asyncStart();
  bool futureWasExecuted = false;
  bool future2WasExecuted = false;

  // Make sure `catchErrors` doesn't close its error stream before all
  // asynchronous operations are done.
  catchErrors(() {
    new Future(() => 499).then((x) {
      futureWasExecuted = true;
    });
    runAsync(() {
      new Future(() => 42).then((x) {
        future2WasExecuted = true;
      });
    });
    return 'allDone';
  }).listen((x) {
      Expect.fail("Unexpected callback");
    },
    onDone: () {
      Expect.isTrue(futureWasExecuted);
      Expect.isTrue(future2WasExecuted);
      asyncEnd();
    });
}
