
postgresql: podman run --rm --name oai-postgres -p 5432:5432 -v ./dat/postgresql:/var/lib/postgresql/data -e POSTGRES_PASSWORD=secret postgres:latest
chroma: podman run --rm --name oai-chroma -p 8000:8000 -v ./dat/chroma:/chroma/chroma -e IS_PERSISTENT=true chromadb/chroma:latest

# web: bundle exec ./config.ru
