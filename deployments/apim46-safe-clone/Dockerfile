ARG WSO2_APIM_BASE=registry.wso2.com/wso2-apim/am:4.6.0.0
FROM ${WSO2_APIM_BASE}

ARG WSO2_SERVER_HOME=/home/wso2carbon/wso2am-4.6.0

USER root

RUN mkdir -p /opt/wso2/bootstrap/sequences /opt/wso2/bootstrap/security

COPY deployments/apim46-safe-clone/container/apim-entrypoint.sh /usr/local/bin/apim-entrypoint.sh
COPY deployments/apim46-safe-clone/build-overlay/dropins/ ${WSO2_SERVER_HOME}/repository/components/dropins/
COPY deployments/apim46-safe-clone/build-overlay/lib/ ${WSO2_SERVER_HOME}/repository/components/lib/

RUN chmod 0555 /usr/local/bin/apim-entrypoint.sh && \
    chown -R 10001:10001 /opt/wso2 ${WSO2_SERVER_HOME}/repository/components/dropins ${WSO2_SERVER_HOME}/repository/components/lib

USER 10001

WORKDIR ${WSO2_SERVER_HOME}

EXPOSE 9453 8253 8290

ENTRYPOINT ["/usr/local/bin/apim-entrypoint.sh"]