// tweetnacl.c declares `extern void randombytes(u8 *,u64);` and calls it only from
// crypto_box_keypair and crypto_sign_keypair. Keys come from CryptoKit, so those
// functions stay unused, but the symbol must exist for tweetnacl.o to link.
// arc4random_buf is the Darwin CSPRNG, so even an accidental call stays secure.
#include <stdlib.h>

void randombytes(unsigned char *x, unsigned long long xlen) {
    arc4random_buf(x, (size_t)xlen);
}
