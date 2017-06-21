# Docker

In order to build the image you need to first build its parent julia-baked:0.5.1.

```bash
time docker build -t aws-cluster-managers-test:latest ./aws-cluster-managers-test

$(aws ecr get-login --region us-east-1)
docker tag aws-cluster-managers-test:latest 292522074875.dkr.ecr.us-east-1.amazonaws.com/aws-cluster-managers-test:latest
docker push 292522074875.dkr.ecr.us-east-1.amazonaws.com/aws-cluster-managers-test:latest
```
