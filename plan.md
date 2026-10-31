# Role

Act as a Senior Flutter Engineer, Supabase Architect, Product Designer, and AI Engineer.

I want to build a graduation project called **Local Service On-Demand Platform**. Help me design and implement it step by step using clean architecture, secure database design, and maintainable code.

Do not start coding immediately. First analyze the requirements, identify risks, design the architecture, and create an implementation roadmap. Wait for my approval before implementing the first milestone.

# 1. Project Overview

Build a mobile application that connects customers with local service providers such as:

- Plumbers
- Electricians
- Carpenters
- Air-conditioning technicians
- Refrigerator and washing machine repair technicians
- Other skilled workers

Customers can publish service requests, describe problems, upload photos, specify their location, receive offers from providers, and choose the most suitable professional.

Providers can create profiles, select their skills and service areas, browse relevant jobs, submit price quotes, manage availability, and track their jobs.

The platform should improve trust, simplify service discovery, and make booking home maintenance services easier.

# 2. Technology Stack

## Mobile Application

- Flutter
- Dart
- Flutter BLoC for state management
- GoRouter for navigation

## Backend Platform

Use **Supabase as the entire backend platform**. Do not build a separate Node.js or Express backend.

Use:

- Supabase Auth for authentication
- PostgreSQL for the database
- Supabase Row Level Security (RLS) for authorization
- Supabase Storage for images and verification documents
- Supabase Realtime for live updates where appropriate
- Supabase Edge Functions for trusted server-side operations and external AI API calls
- PostGIS for geographical queries and distance calculations, if supported by the chosen Supabase setup

Use generated Dart types where practical and keep database migrations in version control.

## AI

- A vision-capable AI model for analyzing images and text descriptions
- Supabase Edge Functions to call the AI provider securely
- A rule-based Smart Matching algorithm initially
- Optional future machine learning improvements

Never expose Supabase service-role credentials or AI API keys in the Flutter application.

# 3. User Roles

Implement three main roles:

### Customer

- Create and manage service requests
- Upload photos of the problem
- Specify location and preferred time
- Receive and compare quotes
- Select a provider
- Track job status
- Confirm completion
- Submit ratings and reviews
- Access service history
- Submit complaints

### Service Provider

- Create and manage a professional profile
- Select skills and supported service categories
- Submit verification documents
- Define service areas and availability
- Browse suitable jobs
- Submit quotes
- Manage accepted jobs
- Upload before-and-after photos
- Update job status
- View ratings and completed work

### Administrator

- Review and verify provider applications
- Manage service categories
- Review complaints and disputes
- Handle reported accounts and suspicious reviews
- Manage warranty claims
- Review platform activity

Enforce permissions in PostgreSQL using RLS and trusted server-side functions. Hiding buttons in Flutter is not a security mechanism.

# 4. Core Features

## A. Authentication and Profiles

- Email/password authentication through Supabase Auth
- Customer and provider onboarding
- Profile management
- Provider skills and service areas
- Verification status
- Availability settings

Design role management so users cannot grant themselves administrator privileges or mark their own provider accounts as verified.

## B. Service Request Marketplace

Customers should be able to:

- Select a service category
- Describe the problem
- Upload multiple images
- Specify their location
- Choose a preferred appointment time
- Submit a request
- Receive and compare provider quotes
- Accept one quote
- Track the service until completion

Providers should be able to:

- Browse eligible open jobs
- Filter by category and distance
- View relevant request details
- Submit a quote with price, estimated duration, and notes
- Withdraw or update a quote according to defined rules

Prevent multiple providers from being selected for the same request through appropriate database constraints and transactional operations.

## C. Smart Matching

Build a matching algorithm that recommends the most suitable providers.

Consider:

- Matching service category and skills
- Distance from the customer
- Provider availability
- Average rating and review count
- Verification status
- Relevant experience
- Previous response and completion rates, when sufficient data exists

Start with hard eligibility filters, followed by a configurable weighted scoring system.

Example initial weights:

- Distance: 35%
- Rating: 25%
- Availability: 20%
- Relevant experience: 20%

Normalize each factor to a score between 0 and 100. Treat these weights as configurable initial assumptions, not proven optimal values.

Requirements:

- Do not recommend providers who lack the required skills.
- Apply the platform's verification policy.
- Handle providers with few or no reviews fairly.
- Avoid penalizing providers when insufficient data exists.
- Explain why a provider is recommended.
- Allow customers to browse other eligible providers.
- Test matching results using realistic sample data.

Use PostGIS for efficient nearby-provider queries if appropriate.

Initially, implement matching through PostgreSQL queries and trusted Supabase functions. Do not introduce a separate machine-learning model without evidence that it is necessary.

## D. AI-Powered Problem Diagnosis

Allow customers to upload a photo and describe their problem.

The AI should:

- Identify the likely service category
- Summarize the visible problem
- Ask useful follow-up questions
- Suggest what information the technician needs
- Produce structured output suitable for creating a service request
- Express uncertainty when the evidence is insufficient

Example:
A customer uploads an air-conditioner photo and reports that it is running but not cooling. The AI may recommend an air-conditioning technician and ask for additional symptoms.

Important constraints:

- A photo alone cannot reliably establish the exact cause of a fault.
- Do not present AI suggestions as confirmed diagnoses.
- Do not recommend dangerous DIY electrical or appliance repairs.
- Require customer confirmation before creating or modifying a request.
- Handle invalid images, timeouts, API failures, and rate limits.
- Do not send private information to the AI provider unnecessarily.

Implement AI calls through Supabase Edge Functions. Keep provider API keys on the server side.

## E. Initial Price Estimation

Implement a transparent pricing system.

The initial estimate can use:

- Service category
- Type of repair
- Visit fee
- Geographic area, when relevant
- Optional urgency surcharge
- Historical completed-job prices when sufficient reliable data exists

Initially use configurable pricing rules rather than relying on an LLM to invent prices.

Display estimates as indicative ranges, not guaranteed final prices.

Providers can submit detailed quotes. Customers must approve additional costs before work continues.

Store monetary values as integer minor currency units, such as Egyptian piastres, rather than floating-point values.

## F. Job Tracking and Notifications

Implement a clear state machine for service requests.

Possible states:

- Open
- Receiving quotes
- Provider selected
- Scheduled
- Provider on the way
- In progress
- Completed
- Cancelled
- Disputed

Define valid state transitions and who can perform each transition.

Use Supabase Realtime for appropriate status updates and Flutter push notifications for important events where practical.

Do not rely on Realtime alone for durable notifications. Persist important notifications and handle reconnects, duplicate events, and offline clients.

## G. Before-and-After Photos and Service History

Allow providers to upload:

- Before-service photos
- After-service photos
- Work notes
- Parts or materials information, when applicable
- Completion details

Customers can view their service history and completed work.

Use private Supabase Storage buckets, scoped access policies, and signed URLs where appropriate. Restrict uploads by file type, size, ownership, and associated job permissions.

## H. Ratings and Trust

Implement:

- Ratings from 1 to 5
- Written reviews
- Provider average ratings
- Completed-job counts
- Verified-provider indicators
- Review reporting

Only customers with eligible completed jobs should be allowed to submit reviews.

Enforce this rule in the database or a trusted function, not just in Flutter. Prevent duplicate reviews for the same job and provide moderation tools.

## I. Complaints and Service Warranties

Customers should be able to open complaints associated with a job.

Store:

- Complaint reason
- Description
- Supporting photos
- Submission time
- Review status
- Administrator decision
- Resolution notes

Allow providers to define or offer warranties subject to platform policy.

Store warranty duration, effective date, expiry date, coverage terms, and claim status.

Do not promise universal warranties. Clearly distinguish provider-offered warranties from platform guarantees.

# 5. Supabase Database Architecture

Design a normalized PostgreSQL schema with appropriate relationships, foreign keys, constraints, indexes, and migrations.

Consider these tables:

- profiles
- provider_profiles
- provider_skills
- provider_service_areas
- provider_availability
- provider_verifications
- service_categories
- service_requests
- service_request_photos
- provider_quotes
- service_jobs
- job_status_history
- job_photos
- reviews
- notifications
- complaints
- service_warranties
- warranty_claims
- ai_diagnoses
- price_estimates

You may revise this list to avoid unnecessary tables or duplicate concepts.

Use UUID identifiers where appropriate, timestamps, and explicit relationships.

Define database constraints for important business rules. Explain which operations require PostgreSQL transactions or trusted database functions.

Keep migrations reproducible and do not depend on manually editing the production database.

# 6. Security Requirements

Security is a core requirement.

Design and test:

- RLS policies for every exposed table
- Private Storage access and upload policies
- Role and ownership validation
- Safe provider verification
- Protection against unauthorized job access
- Protection against quote manipulation
- Prevention of fake or duplicate reviews
- Validation of AI-generated structured outputs
- Rate limiting for expensive operations
- Safe handling of uploaded files
- Secure Edge Function configuration
- Protection against abuse and spam
- Auditing of administrative decisions

Customers must not access other customers' private requests. Providers must not modify other providers' quotes or profiles. Users must not bypass verification or alter privileged roles.

Use the Supabase publishable key in the client with correctly configured RLS. Never embed a service-role key or secret AI key in the mobile application.

# 7. Flutter Architecture

Use a feature-first project structure with clear separation of:

- Presentation
- BLoC/Cubit state management
- Domain logic where useful
- Data sources
- Repositories
- Models and generated types
- Supabase integrations

Separate customer, provider, and administrator experiences logically.

Design screens for:

1. Authentication
2. Customer onboarding
3. Provider onboarding and verification
4. Home and service categories
5. Create service request
6. AI problem assistant
7. Nearby providers
8. Quotes comparison
9. Job details and tracking
10. Provider job feed
11. Provider quote submission
12. Job management
13. Before-and-after photos
14. Reviews
15. Service history
16. Complaints and warranty claims
17. Notifications
18. Profile and settings

Create a consistent Arabic-friendly interface and support right-to-left layouts. Keep localization extensible so English can be added later.

Use proper loading, empty, success, offline, and error states.

# 8. Testing Strategy

Include:

- Flutter unit tests
- BLoC tests
- Widget tests
- Supabase integration tests
- Database constraint tests
- RLS authorization tests
- Storage permission tests
- Smart Matching tests
- AI output validation tests
- Job lifecycle tests
- Quote acceptance concurrency tests
- Review eligibility tests
- Complaint and warranty workflow tests

Create realistic test scenarios involving multiple customers and providers.

Test unauthorized access explicitly, including attempts to read another user's data or update privileged fields.

# 9. Implementation Roadmap

Divide implementation into these milestones:

1. Requirements, architecture, and UI flow
2. Supabase project setup and database migrations
3. Authentication and role-based onboarding
4. Provider profiles, categories, and verification
5. Service requests and image uploads
6. Quotes and job lifecycle
7. Smart Matching
8. Reviews and service history
9. Notifications and Realtime updates
10. AI diagnosis through Edge Functions
11. Price estimation
12. Complaints and warranty workflows
13. Security testing, optimization, and final demonstration

For each milestone provide:

- Goals
- Database changes
- Flutter screens
- Supabase integrations
- Security policies
- Tests
- Acceptance criteria
- Dependencies and risks

Identify features that can be developed in parallel without causing integration problems.

# 10. Development Rules

- Do not generate the entire application in one response.
- Do not start coding before presenting the architecture and roadmap.
- Wait for my approval before starting implementation.
- Work on one milestone at a time.
- Explain important technical decisions.
- Prefer simple, maintainable solutions over unnecessary abstractions.
- Use Supabase as the backend; do not create a separate Express or Node.js API.
- Use Edge Functions or database functions only where trusted server-side execution is needed.
- Include SQL migrations and RLS policies with the relevant database features.
- Never claim that a security rule works without testing it.
- Use environment variables and Supabase secrets appropriately.
- Never invent API keys, credentials, or configuration values.
- Provide exact commands to run and test each milestone.
- Keep the project runnable at every major milestone.
- Do not move to the next milestone until I approve the current one.

# First Task

Start by analyzing the requirements and producing:

1. System architecture
2. Mermaid architecture diagram
3. Main user workflows
4. Database schema and relationships
5. RLS and Storage security strategy
6. Flutter folder structure
7. Supabase Edge Functions design
8. Smart Matching algorithm design
9. AI diagnosis integration plan
10. Milestone-based implementation roadmap
11. Testing and acceptance criteria

Do not write implementation code yet. Finish with the recommended first milestone and wait for my approval.
