FROM nginx:1.27-alpine
LABEL org.opencontainers.image.source="https://github.com/equinix-svc/svc-helm-daihub"
ENV DEMO_KEY="" NGINX_ENTRYPOINT_LOCAL_RESOLVERS=1
COPY default.conf.template /etc/nginx/templates/default.conf.template
COPY index.html equinix-logo.svg /usr/share/nginx/html/chat/
