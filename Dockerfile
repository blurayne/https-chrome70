FROM nginx:1.15.7-alpine

RUN \
    apk add openssl \
    && rm /etc/nginx/conf.d/default.conf 

COPY nginx/cert/dhparam.pem /etc/nginx/cert/dhparam.pem