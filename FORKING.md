# Forking OCP Desktop and Official Service Boundaries

OCP Desktop is distributed under Apache-2.0. Forking, modifying and rebuilding the public Desktop source is allowed under that license.

## What a fork can change

A fork can replace or remove client-side integrations, including:

- Store endpoint
- update endpoint
- package trust roots
- UI and Runtime behavior
- AI providers
- application branding
- plugin/package behavior

That freedom is part of the open-source model.

## What is not included in the public source

The public Desktop source does not contain private credentials or administrative authority for official OCP services. In particular it does not publish:

- marketplace private signing keys
- production update private signing keys
- SignPath or other code-signing credentials
- Supabase service-role credentials
- R2 credentials
- Creator/Operations administrative credentials
- private moderation or deployment credentials

Public verification keys and protocol/schema definitions may be included because clients need them to verify official data and packages.

## Official OCP identity

An independently built fork is not an official OCP release merely because it originates from OCP source. Official releases are distinguished by the project's approved build provenance, signing identity, update signatures, release channel and hosted-service authorization.

Fork maintainers should use their own product name/logo where appropriate, application identifier, signing certificate, update key and service endpoints so users can distinguish the fork from official OCP builds.

## Official hosted services

The OCP Store and related hosted services enforce authorization server-side. A modified client cannot obtain official publisher/admin authority simply by changing local source code. Access to official publishing, moderation, entitlement and signing operations depends on server-side identity and authorization.

A fork may operate its own compatible service and trust root. That service is independent of the official OCP ecosystem.

## Contributions back to OCP

Useful fork changes can be proposed through pull requests to the public Desktop repository. Accepted changes go through maintainer review and the private integration test/security pipeline before they are exported back to the public source.

Project contact: `opencompanionplatform@gmail.com`.
