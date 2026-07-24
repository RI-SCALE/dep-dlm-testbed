# RI-SCALE Presentation Script
**Total Time: 15 minutes (10 min presentation + 5 min Q&A)**
**Slide timing: ~45-60 seconds per slide**

---

## Slide 1: Title Slide (30 seconds)
**Opening:** "Good morning everyone. I'm Marvin Gajek from CERN, and I'm excited to share how we're building a data exploitation platform for European Research Infrastructures using Rucio and FTS as our core orchestration layer."

**Key message:** Set the stage - this is about scaling proven CERN technologies to broader European research.

---

## Slide 2: What is RI-SCALE? (60 seconds)
**Script:** "RI-SCALE is a €10.5 million European project with 29 partners across 13 countries. Our mission is ambitious but clear - we have over 2 petabytes of underutilized scientific datasets scattered across European facilities, and we need to unlock their scientific value through AI-driven analysis platforms."

**Key points to emphasize:**
- Scale of the challenge (2+ PB)
- European collaboration scope
- Focus on underutilized data

---

## Slide 3: Participants (30 seconds)
**Script:** "Our consortium brings together Europe's leading research organizations, from CERN and DESY to major universities and commercial partners. This diversity is both our strength and our challenge - we need to federate data across very different infrastructures."

**Key message:** Diversity requires robust data orchestration solutions.

---

## Slide 4: Key Use Cases (60 seconds)
**Script:** "We're not building abstract infrastructure - we have concrete scientific use cases driving our design. From climate science requiring high-resolution weather data processing, to space research with intelligent radar scheduling, to medical imaging for cancer prediction. Each requires moving and processing massive datasets efficiently."

**Key message:** Real science problems driving technical requirements.

---

## Slide 5: Challenge & Why Rucio+FTS? (75 seconds)
**Script:** "This brings us to our core challenge and why we chose Rucio. On the left, you see the problems - distributed data, limited access, complex authentication. On the right, why Rucio+FTS is perfect for this. It's proven at CERN's scale, handles distributed data natively, and has the flexible authentication we need for multi-institutional collaboration."

**Key message:** Rucio isn't just technically suitable - it's the obvious choice for this scale of challenge.

---

## Slide 6: Architecture Overview (45 seconds)
**Script:** "This shows our complete platform architecture. You can see how users interact through different roles - data scientists, domain experts, administrators - and how data flows through our orchestration layer to various compute and storage resources."

**Key message:** Comprehensive but user-focused design.

---

## Slide 7: Data Lifecycle Management (45 seconds)
**Script:** "Here's the heart of our system - the data lifecycle management layer powered by Rucio and FTS. This handles data discovery, transfer coordination, and preparation across all our distributed European facilities."

**Key message:** Rucio+FTS as the orchestration backbone.

---

## Slide 8: Architecture Components (60 seconds)
**Script:** "Our architecture has five key components. Data orchestration through Rucio and FTS handles the heavy lifting. Multi-IdP OIDC authentication manages access across institutions. Data services provide discovery and popularity tracking. The AI Model Hub integrates with EuroHPC for computation. And external integration connects to existing data holdings and spaces."

**Key message:** Integrated solution addressing all aspects of the data lifecycle.

---

## Slide 9: Scientific Data Workflow Phases (75 seconds)
**Script:** "We've designed this around a five-phase scientific workflow. Phase 1 is discovery and access - finding data and getting it where you need it. Phase 2 is preparation - cleaning and transforming. Phase 3 is model exploration using our AI hub. Phase 4 is the actual computation and analysis. Phase 5 is results and feedback, including storing improved models. Rucio orchestrates data movement throughout all phases."

**Key message:** End-to-end workflow design with Rucio integration at every step.

---

## Slide 10: Current Implementation Status (60 seconds)
**Script:** "So where are we today? We have a working GitOps-based Rucio deployment that consortium partners can use. We've completed comprehensive documentation including API mappings for all workflow phases. We're building integration testing infrastructure and designing our OIDC authentication blueprint."

**Key message:** Real progress, not just planning.

---

## Slide 11: Key Challenges & Solutions (75 seconds)
**Script:** "Let me highlight our key technical challenges and solutions. Multi-IdP integration across research facilities - we're solving this with a single token approach and centralized introspection. Distributed data orchestration across 2+ petabytes - Rucio's RSE topology with network optimization handles this perfectly. Workflow complexity - we've mapped REST APIs for each phase. Storage heterogeneity - unified protocol configuration with QoS policies."

**Key message:** We understand the challenges and have concrete technical solutions.

---

## Slide 12: Technical Implementation Details (60 seconds)
**Script:** "On the technical side, we're implementing automated OIDC identity mapping, third-party copy workflows with FTS, hierarchical storage topology, complete REST API coverage, and real-time monitoring with our Data Popularity Service for intelligent caching."

**Key message:** Deep technical integration with Rucio ecosystem.

---

## Slide 13: Roadmap & Impact (75 seconds)
**Script:** "Looking ahead, short-term we're completing our prototype and authentication blueprint. Medium-term we integrate multiple identity providers and data repositories. Long-term we achieve full data holdings integration and multiple platform deployments. The impact? Secure, scalable data access for European research infrastructures, plus our contributions back to the Rucio community."

**Key message:** Clear timeline with community benefits.

---

## Slide 14: Thank You (15 seconds)
**Script:** "Thank you for your attention. I'm excited to discuss how this might benefit your own Rucio deployments and how we can collaborate. Questions?"

**Key message:** Open for collaboration and discussion.

---

## Backup Speaking Points (if you need to fill time or handle questions):

**On Scale:** "To put this in perspective, 2+ petabytes is roughly equivalent to streaming Netflix in 4K for 2 years straight - and we need to make this accessible to researchers across Europe."

**On Rucio Benefits:** "What excites me most is that Rucio gives us the proven reliability of CERN's data management with the flexibility to adapt to research infrastructure needs."

**On Timeline:** "We're moving fast but deliberately - prototype deployment this year, integration next year, full deployment by 2027-2028."

**On Community:** "This isn't just about RI-SCALE - everything we develop gets contributed back to Rucio, potentially benefiting anyone managing distributed scientific data."

## Emergency Slides (if running short on time):
- Can combine slides 6+7 (both architecture overviews)
- Can shorten slide 9 (workflow phases) to just mention "5-phase workflow"
- Can skip slide 12 (technical details) if audience seems less technical

## If Running Over Time:
- Skip detailed explanations on architecture slides
- Focus on challenges/solutions and roadmap
- Keep use cases brief
