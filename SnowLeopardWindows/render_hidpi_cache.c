/*
 * Inserted into render_hidpi (only) with DYLD_INSERT_LIBRARIES; see render_hidpi.m.
 * Mavericks' CGSSharedArtworkCache() returns NULL and its cache functions do
 * nothing; ScalableUserInterface only needs the pointer to be non-NULL.
 */
extern void *CGSSharedArtworkCache(void);

static void *SLDummyArtworkCache(void)
{
    static char dummy[64];
    return dummy;
}

__attribute__((used)) static const struct { const void *replacement, *original; } interposers[]
    __attribute__((section("__DATA,__interpose"))) = {
    { (const void *)SLDummyArtworkCache, (const void *)CGSSharedArtworkCache },
};
