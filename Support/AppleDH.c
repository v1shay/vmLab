#include <openssl/bn.h>
#include <openssl/crypto.h>

int vmlab_apple_dh(unsigned generator, int length, const unsigned char *modulus,
                   const unsigned char *peer, unsigned char *public_key, unsigned char *secret) {
    BN_CTX *ctx = BN_CTX_new();
    if (!ctx) return 0;
    BN_CTX_start(ctx);
    BIGNUM *p = BN_CTX_get(ctx), *remote = BN_CTX_get(ctx), *g = BN_CTX_get(ctx);
    BIGNUM *priv = BN_CTX_get(ctx), *pub = BN_CTX_get(ctx), *shared = BN_CTX_get(ctx);
    BIGNUM *upper = BN_CTX_get(ctx);
    int ok = upper && BN_bin2bn(modulus, length, p) && BN_bin2bn(peer, length, remote)
        && BN_is_odd(p) && BN_num_bits(p) >= 512
        && BN_copy(upper, p) && BN_sub_word(upper, 1)
        && generator >= 2 && BN_set_word(g, generator) && BN_cmp(g, upper) < 0
        && BN_cmp(remote, BN_value_one()) > 0 && BN_cmp(remote, upper) < 0
        && BN_priv_rand(priv, 256, BN_RAND_TOP_ONE, BN_RAND_BOTTOM_ANY)
        && BN_mod_exp_mont_consttime(pub, g, priv, p, ctx, NULL)
        && BN_mod_exp_mont_consttime(shared, remote, priv, p, ctx, NULL)
        && BN_bn2binpad(pub, public_key, length) == length
        && BN_bn2binpad(shared, secret, length) == length;
    if (priv) BN_clear(priv);
    if (shared) BN_clear(shared);
    BN_CTX_end(ctx);
    BN_CTX_free(ctx);
    return ok;
}
