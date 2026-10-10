#include "clib.h"

#include <math.h>

int clib_add(int left, int right) {
    return left + right;
}

double clib_length(clib_point point) {
    return sqrt((double)(point.x * point.x + point.y * point.y));
}
