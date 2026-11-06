/* A stand-in board for the Pico question: a reset entry that calls the
 * program's main, and an output hook that writes to a UART data register.
 * Real firmware also needs the RP2040's boot stage and a vector table; this
 * only proves that generated C and the Zig runtime link for a Cortex-M0+
 * with no operating system. */
#include <stdint.h>
#include <stddef.h>

#define UART0_DR (*(volatile uint32_t *)0x40034000u)

void em_board_write(int fd, const uint8_t *bytes, size_t len) {
    (void)fd;
    for (size_t i = 0; i < len; i++) UART0_DR = bytes[i];
}

int main(void);

void _start(void) {
    main();
    for (;;) {}
}
