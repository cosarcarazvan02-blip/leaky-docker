FROM eclipse-temurin:21-jdk
WORKDIR /app
COPY secrets.env /app/secrets.env
RUN echo "folosesc secretul la build..." && cat /app/secrets.env > /dev/null
RUN rm /app/secrets.env
COPY App.java /app/
RUN javac App.java
CMD ["java", "App"]

