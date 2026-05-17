# Offline-first capture/edit; publish is the only network surface

The entire capture → convert → edit → preview flow works without signal. The trainer can hold a full session in a basement gym and the app behaves identically to being online. Only Publish hits the network — credit consumption is the load-bearing reason it has to, and it's gated by the atomic `consume_credit` RPC.
