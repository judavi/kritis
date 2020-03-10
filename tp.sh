make build-image
docker build -f Dockerfile -t tt .
docker tag tt docker.io/judavi/kritis-alpine:2.0
#docker tag gcr.io/kritis-project/kritis-server:588f70e090ad2ee4c98e65a6d105976ade4aabb2 docker.io/judavi/kritis-alpine
docker push docker.io/judavi/kritis-alpine:2.0
