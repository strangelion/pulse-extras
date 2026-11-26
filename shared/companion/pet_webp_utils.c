/* Only this translation unit redirects libc calls in pinned libwebp utils.c.
 * The upstream source and its checked multiplication remain intact.
 * No process-wide malloc override; decoder threads are disabled. */
#include <stdlib.h>
#include <assert.h>
#include "pet_webp_budget.h"

static pet_webp_budget *active_budget;
static int poisoned;

/* Caller holds the companion decoder lock for the whole scope. */
int pet_webp_budget_begin(pet_webp_budget *budget) {
    if (poisoned || active_budget || !budget || budget->live) return 0;
    active_budget = budget;
    return 1;
}

int pet_webp_budget_end(void) {
    assert(active_budget);
    int drained = active_budget->live == 0;
    if (!drained) poisoned = 1;
    active_budget = NULL;
    return drained;
}

static void *scoped_malloc(size_t size) {
    return pet_webp_budget_alloc(active_budget, 1, size, 0);
}
static void *scoped_calloc(size_t count, size_t size) {
    return pet_webp_budget_alloc(active_budget, count, size, 1);
}
static void scoped_free(void *ptr) {
    if (!ptr) return;
    assert(active_budget && active_budget->live);
    pet_webp_budget_free(active_budget, ptr);
}

#define malloc scoped_malloc
#define calloc scoped_calloc
#define free scoped_free
#include "src/utils/utils.c"
#undef malloc
#undef calloc
#undef free
