FROM python:3.14-alpine
RUN apk add --no-cache git git-daemon && mkdir -p /srv
COPY serve.py /serve.py
EXPOSE 8000
CMD ["python", "/serve.py"]
