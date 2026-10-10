#ifndef CLIB_H
#define CLIB_H

typedef struct clib_point {
    int x;
    int y;
} clib_point;

/// Adds two numbers.
int clib_add(int left, int right);

/// The length of a vector.
double clib_length(clib_point point);

#endif
