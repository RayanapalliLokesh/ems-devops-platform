# ADR 0002: Two versions: Full Local and Playground

- Status: accepted

## Context
The cloud target is AWS through the KodeKloud playground. It limits regions, EC2 sizes and EBS volumes, offers no
NAT gateway, may deny custom IAM roles, blocks managed EKS node groups and caps pods (3 per namespace, 256m CPU and
512Mi each). A session lasts a few hours and is wiped.

## Decision
Build the complete platform for one Ubuntu machine (Linux services, then Compose, then kind). Build a playground
version from the same code that fits the limits: one EC2 host behind a load balancer, and an optional EKS overlay
with reduced size. Whatever only an unrestricted account can run (a NAT gateway, the `prod` environment) is still
written, checked statically and reviewed as a plan.

## Consequences
+ shows end-to-end skill and constrained-environment skill; + nothing depends on a paid account;
- two paths to document and test; - some cloud steps cannot be executed by every learner.
