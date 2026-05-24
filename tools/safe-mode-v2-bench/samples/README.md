# Bench samples

Drop your test inputs here. **Nothing in this folder gets committed** —
the `.gitignore` excludes `*.jpg`, `*.png`, `*.heic`, `*.bin` so real
faces and embeddings stay out of git history.

## Typical layout

```
samples/
  selfie_01.jpg        <- a test selfie (the face you want sharp)
  bystander_01.jpg     <- bystander-in-frame test capture
  embedding.bin        <- 2048 bytes = 512 FP32 little-endian floats
```

## Getting an embedding

```bash
# Make sure STAGING_DB_URL is set — see ../fetch_embedding.sh --help
export STAGING_DB_URL='postgresql://postgres.vadjvkmldtoeyspyoqbx:PWD@aws-…:6543/postgres'

# Then pull the embedding for your test client:
../fetch_embedding.sh 53004519-9b14-45d2-87c0-ac376b19b0b7 > embedding.bin
```

## Running a sweep

```bash
cd ..
./sweep.sh samples/selfie_01.jpg samples/embedding.bin
```

That writes safe variants for thresholds 0.10 -> 0.70 to
`/tmp/safe_mode_bench/<photo_basename>/` and opens an HTML grid in your
browser for side-by-side inspection.
