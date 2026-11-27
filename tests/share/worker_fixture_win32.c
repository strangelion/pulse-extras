/* Deliberate early process exit: verifies parent cleanup, never publishes. */
#include <windows.h>
int main(void) {
    ExitProcess(23);
    return 23;
}
