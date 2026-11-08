#define Py_BUILD_CORE 1

#include "Python.h"
#define _PyObject_MIN_ALIGNMENT 8  // TODO: an arocc bug?
#include "internal/pycore_interpframe_structs.h"
#include "internal/pycore_interp_structs.h"
#include "internal/pycore_debug_offsets.h"
