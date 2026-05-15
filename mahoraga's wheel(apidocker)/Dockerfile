FROM python:3.12-alpine

WORKDIR /app
COPY proxy.py .

RUN mkdir /keys

EXPOSE 8080
CMD ["python", "-u", "proxy.py"]
