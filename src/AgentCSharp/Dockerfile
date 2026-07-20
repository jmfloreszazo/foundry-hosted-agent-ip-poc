# Target platform is linux/amd64 (Foundry Hosted Agents requirement).
# Pass --platform linux/amd64 to `docker build` / `az acr build`; we don't set
# it in FROM because ACR Tasks' dependency scanner cannot parse that syntax.
FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
WORKDIR /src
COPY AgentCSharp.csproj .
RUN dotnet restore
COPY . .
# Deterministic build: same source -> same binary, required to be able to
# verify provenance / signature reproducibly.
RUN dotnet publish AgentCSharp.csproj -c Release -o /app \
    /p:Deterministic=true /p:ContinuousIntegrationBuild=true

FROM mcr.microsoft.com/dotnet/aspnet:10.0 AS runtime
WORKDIR /app
# Non-root user: the binary (IP) runs with minimum privilege in the sandbox.
# Use a numeric UID directly — `adduser` isn't present in every slim base
# image, and Kestrel doesn't need a real /etc/passwd entry.
USER 1000:1000
COPY --from=build /app .
# Azure.AI.AgentServer.Core binds Kestrel to the port in the PORT env var
# (default 8088). Foundry Hosted Agents inject PORT at runtime; for local
# runs, pass -e PORT=8080 -p 8080:8080 to `docker run`.
ENV PORT=8080
EXPOSE 8080
ENTRYPOINT ["dotnet", "AgentCSharp.dll"]
