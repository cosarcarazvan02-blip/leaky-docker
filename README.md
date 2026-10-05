# leaky-docker

Deleting a secret in a Dockerfile doesn't remove it from the image. This repo shows how to recover "deleted" AWS credentials from a Docker image using only `docker save` and `tar`, and how to fix the build with BuildKit secret mounts.

The credentials in `secrets.env` are the official example keys from the AWS documentation. They are not real and don't work anywhere.

## Background

Every instruction in a Dockerfile creates a new layer, and layers are read-only. When a later step runs `rm` on a file, Docker doesn't remove it from the earlier layer. It adds a new layer with a "whiteout" marker that hides the file. Anyone who has the image can still read the original layer.

This isn't just theoretical. Dahlmanns et al. (ASIA CCS 2023, "Secrets Revealed in Container Images") scanned public images on Docker Hub and found large numbers of leaked private keys and API secrets.

## Files

| File | Purpose |
|---|---|
| `Dockerfile` | Vulnerable build: copies `secrets.env`, uses it, then deletes it |
| `Dockerfile.secure` | Fixed build using a BuildKit secret mount |
| `App.java` | Minimal Java app so the image actually runs something |
| `secrets.env` | Fake AWS credentials used in the demo |
| `.dockerignore` | Keeps `secrets.env` and demo artifacts out of the build context |

## Requirements

- Docker with BuildKit (Docker Desktop has it by default)
- `tar` and `grep`

## 1. The vulnerable build

```bash
docker build -t leaky-app .
docker run --rm leaky-app ls -la /app
```

The secrets file is not in `/app`. It looks safe.

## 2. Attack

**Recon with `docker history`.** The build commands are stored in the image metadata, so you can see that a file called `secrets.env` was copied in and later removed. The `rm` step doesn't shrink the image, it adds another layer:

```bash
docker history leaky-app
```

![docker history output](images/docker-history.png)

**Extract the layers** and look for the file:

```bash
docker save leaky-app -o leaky.tar
mkdir extract && tar -xf leaky.tar -C extract
cd extract
for f in blobs/sha256/*; do
  tar -tf "$f" 2>/dev/null | grep -q "secrets.env" && echo "Found in: $f"
done
```

Two layers match. One contains `app/.wh.secrets.env` (the whiteout from `rm`). The other contains the original file:

```bash
tar -xOf blobs/sha256/<layer-hash> app/secrets.env
```

![extracted AWS keys](images/extracted-keys.png)

## 3. The fix

`Dockerfile.secure` mounts the secret only for the duration of a single `RUN` step. It is never written to a layer:

```dockerfile
RUN --mount=type=secret,id=aws_creds \
    cat /run/secrets/aws_creds > /dev/null
```

```bash
docker build --secret id=aws_creds,src=secrets.env -f Dockerfile.secure -t safe-app .
```

## 4. Verification

Instead of searching by file name, search every file in every layer for the key itself:

```bash
for f in blobs/sha256/*; do
  tar -xOf "$f" 2>/dev/null | grep -a -q "AKIAIOSFODNN7EXAMPLE" && echo "Key found in: $f"
done
```

| | `leaky-app` | `safe-app` |
|---|---|---|
| Layer with `COPY secrets.env` | yes | no |
| Layer with `rm secrets.env` | yes | no |
| Key found by content search | 1 layer | none |
| App runs | yes | yes |

## Notes

- Build args (`ARG`) and `ENV` values leak in a similar way: they show up in `docker history` or the image config.
- Multi-stage builds also help, as long as the secret only exists in a stage that isn't copied into the final image.
- If a real secret ever ends up in an image that was pushed somewhere, deleting the image isn't enough. Rotate the secret.

## What I learned

I assumed that if a file wasn't in the final container, it wasn't in the image. That's wrong. An image is a stack of layers, and `rm` only hides a file from the layers below it. Recovering the keys didn't need any special tools, just `docker save` and `tar`, which is what made it surprising. The fix is simple once you know about it, but it's easy to miss, especially when a Dockerfile "works" and nothing looks wrong.

## References

- Dahlmanns et al., "Secrets Revealed in Container Images: An Internet-wide Study on Occurrence and Impact", ASIA CCS 2023
- Docker docs, Build secrets: https://docs.docker.com/build/building/secrets/
