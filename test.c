#include <assert.h>
#include <errno.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

typedef struct {
	unsigned long ul;
} ulong_t;
int main(void)
{ 	
	return sizeof(ulong_t) == sizeof(unsigned long);
}
