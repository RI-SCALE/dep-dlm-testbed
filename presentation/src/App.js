import React, { useState } from 'react';
import { ChevronLeft, ChevronRight } from 'lucide-react';

function App() {
  const [currentSlide, setCurrentSlide] = useState(0);

const slides = [
  {
    type: 'title',
    title: 'dep-dlm-testbed',
    subtitle: 'End-to-End Validation for the RI-SCALE Data Lifecycle Management Layer',
    author: 'Marvin Gajek',
    footer: 'RI-SCALE Project'
  },

  {
    type: 'content',
    title: 'What is dep-dlm-testbed?',
    content: [
      {
        heading: 'Mission',
        text: 'Prove the DEP DLM data-orchestration layer end-to-end, against real infrastructure, before any RI partner deploys it for real.'
      },
      {
        heading: 'Scope',
        text: 'A self-contained, containerized stack — deployable via Docker Compose or Kubernetes and GitOps-managed across sandbox, staging and production — that validates authentication, data transfers and replication rule lifecycles end-to-end.'
      },
      {
        heading: 'Status',
        text: 'Sandbox environment validated end-to-end. Staging and production environments are defined and converging next.'
      }
    ]
  },

  {
    type: 'twocolumn',
    title: 'Why a Testbed, Not Just an Architecture Doc?',
    left: {
      heading: 'What a doc cannot catch',
      items: [
        'Identity providers behaving differently in practice than their documentation describes',
        'Components that pass review individually but fail once actually running together',
        'Small configuration mistakes that fail silently instead of loudly',
        'Whether a design decision made for one partner actually generalizes to a second'
      ]
    },
    right: {
      heading: 'What the testbed proves instead',
      items: [
        'Constraints hit so far were diagnosed and fixed against real infrastructure — once, not per partner',
        'A continuous testing matrix covering multiple deployment methods, authentication modes and identity providers',
        'Fixes are proven with a passing automated test, not just a reviewed code change',
        'The risk-reduction step before deployment in staging or production environments'
      ]
    }
  },

  {
    type: 'imagepair',
    title: 'Architecture: Sandbox \u2192 Staging & Production',
    description: 'Sandbox bundles everything internally for fast, dependency-free iteration. Staging and production externalize secrets, identity and storage \u2014 the shape a real deployment actually has. The architecture itself doesn\u2019t change; only what\u2019s internal vs. external does.',
    images: [
      { src: 'sandbox.png', caption: 'Sandbox \u2014 fully internal' },
      { src: 'staging.png', caption: 'Staging & Production \u2014 externalized' }
    ]
  },

  {
    type: 'content',
    title: 'What\u2019s Validated Today',
    bullets: [
      'Identity-based authentication against a real external identity provider \u2014 you\u2019ll see this as rucio whoami',
      'File upload and download validated end-to-end against real storage \u2014 rucio upload / rucio download',
      'The full lifecycle of a data-replication rule, from creation to cleanup'
    ]
  },

  {
    type: 'content',
    title: 'Why GitOps',
    content: [
      {
        heading: 'One source of truth',
        text: 'Every environment\u2019s desired state \u2014 what\u2019s deployed and how it\u2019s configured \u2014 lives in git.'
      },
      {
        heading: 'Tool-agnostic by design',
        text: 'The deployment definitions work with either of the two leading GitOps engines (Argo CD or Flux) \u2014 partners already committed to one aren\u2019t forced to adopt the other.'
      },
      {
        heading: 'Auditable and reversible',
        text: 'Every change to what\u2019s running is a commit: reviewable before it happens and traceable after \u2014 including secrets, which are provisioned securely rather than stored in the repository.'
      }
    ]
  },

  {
    type: 'content',
    title: 'The Ask: From Testbed to dep-dlm-gitops',
    content: [
      {
        heading: 'What exists today',
        text: 'A validated set of deployment definitions and environment-specific configuration, working on both Argo CD and Flux.'
      },
      {
        heading: 'What we\u2019re proposing',
        text: 'Extract this into a dedicated GitOps repository: the shared core stays single-copy and version-pinned, while each RI partner gets its own environment configuration and its own isolated secrets store \u2014 never a shared one across partners.'
      },
      {
        heading: 'Why this, not four separate forks',
        text: 'A fix to the shared core becomes a version bump for each partner, not four manual merges. Onboarding a new partner is adding one environment configuration, not a new repository to keep in sync forever — and not a single shared instance split across teams the way the first CERN deployment was.'
      },
      {
        heading: 'What a partner actually owns',
        text: 'Their own complete DEP DLM instance — Rucio, FTS and everything around it — not a slice of one shared between multiple teams.'
      }
    ]
  },

  {
    type: 'content',
    title: 'Roadmap',
    content: [
      {
        heading: 'Now',
        text: 'Integrating a second external identity provider \u2014 confirming its constraints before writing any integration code, the same way the first provider was validated first.'
      },
      {
        heading: 'Next',
        text: 'Provisioning the external infrastructure that staging and production already assume exists \u2014 e.g. secrets storage and databases \u2014 on real cloud or on premise infrastructure.'
      },
      {
        heading: 'Near term',
        text: 'A dedicated GitOps repository live, with the shared core version-pinned and the first partner environment onboarded as the reference implementation.'
      },
      {
        heading: 'Impact',
        text: 'Every RI partner deploys DEP DLM against infrastructure that has already failed safely once, in this testbed, instead of in their own cluster.'
      }
    ]
  },

  {
    type: 'closing',
    title: 'Thank You',
    content: 'Up next: a live demo \u2014 sandbox login, upload, download',
    contact: [
      'Project: RI-SCALE \u2014 DEP DLM',
      'Contact: marvin.gajek@cern.ch',
      'More info: https://www.riscale.eu'
    ]
  }
];

  const nextSlide = () => {
    if (currentSlide < slides.length - 1) {
      setCurrentSlide(currentSlide + 1);
    }
  };

  const prevSlide = () => {
    if (currentSlide > 0) {
      setCurrentSlide(currentSlide - 1);
    }
  };

  const slide = slides[currentSlide];

  return (
    <div className="w-full h-screen bg-white flex flex-col relative">
      {/* Header with logos */}
      <div className="absolute top-0 left-0 right-0 flex justify-between items-start p-6 z-10">
        <img
          src="/assets/ri-scale-logo-top-left.png"
          alt="RI-SCALE Logo"
          className="h-16 w-auto"
        />
        <img
          src="/assets/logo-top-right.png"
          alt="Decorative graphics"
          className="h-20 w-auto"
        />
      </div>


      {/* Footer with EU funding logo */}
      <div className="absolute bottom-14 left-0 p-6 z-10">
        <img
          src="/assets/funded-bottom-left.png"
          alt="Funded by the European Union"
          className="h-8 w-auto"
        />
      </div>

      {/* Slide Content */}
      <div className="flex-1 flex items-center justify-center p-8 pt-24 pb-20 overflow-y-auto">
        <div className="w-full max-w-5xl slide-content">
          {slide.type === 'title' && (
            <div className="text-center space-y-8">
              <h1 className="text-5xl font-bold text-gray-900 mb-4">{slide.title}</h1>
              <p className="text-2xl text-orange-400">{slide.subtitle}</p>
              <p className="text-xl text-gray-700 mt-8">{slide.author}</p>
              <p className="text-lg text-gray-600">{slide.footer}</p>
            </div>
          )}

          {slide.type === 'content' && (
            <div className="space-y-6">
              <h2 className="text-4xl font-bold text-gray-900 mb-8">{slide.title}</h2>
              {slide.bullets && (
                <ul className="space-y-4">
                  {slide.bullets.map((bullet, idx) => (
                    <li key={idx} className="text-xl text-gray-800 flex items-start">
                      <span className="text-orange-500 mr-3">▸</span>
                      <span>{bullet}</span>
                    </li>
                  ))}
                </ul>
              )}
              {slide.content && (
                <div className="space-y-6">
                  {slide.content.map((item, idx) => (
                    <div key={idx} className="bg-gray-50 p-6 rounded-lg border border-gray-200">
                      <h3 className="text-2xl font-semibold text-orange-400 mb-3">{item.heading}</h3>
                      <p className="text-lg text-gray-700">{item.text}</p>
                    </div>
                  ))}
                </div>
              )}
            </div>
          )}

          {slide.type === 'twocolumn' && (
            <div className="space-y-6">
              <h2 className="text-4xl font-bold text-gray-900 mb-8">{slide.title}</h2>
              <div className="grid grid-cols-2 gap-8">
                <div className="bg-red-50 p-6 rounded-lg border border-red-200">
                  <h3 className="text-2xl font-semibold text-red-700 mb-4">{slide.left.heading}</h3>
                  <ul className="space-y-3">
                    {slide.left.items.map((item, idx) => (
                      <li key={idx} className="text-lg text-gray-700 flex items-start">
                        <span className="text-red-500 mr-3">✗</span>
                        <span>{item}</span>
                      </li>
                    ))}
                  </ul>
                </div>
                <div className="bg-green-50 p-6 rounded-lg border border-green-200">
                  <h3 className="text-2xl font-semibold text-green-700 mb-4">{slide.right.heading}</h3>
                  <ul className="space-y-3">
                    {slide.right.items.map((item, idx) => (
                      <li key={idx} className="text-lg text-gray-700 flex items-start">
                        <span className="text-green-500 mr-3">✓</span>
                        <span>{item}</span>
                      </li>
                    ))}
                  </ul>
                </div>
              </div>
            </div>
          )}

          {(slide.type === 'image' || slide.type === 'image2') && (
            <div className="space-y-6 text-center">
              <h2 className="text-4xl font-bold text-gray-900 mb-4">{slide.title}</h2>
              {slide.description && (
                <p className="text-lg text-gray-600 max-w-3xl mx-auto">{slide.description}</p>
              )}
              <div className="flex justify-center">
                <img
                  src={`/assets/${slide.image}`}
                  alt={slide.title}
                  className="max-h-[550px] w-auto border border-gray-300 rounded-lg shadow-lg bg-white p-4"
                />
              </div>
            </div>
          )}

          {slide.type === 'imagepair' && (
            <div className="space-y-6 text-center">
              <h2 className="text-4xl font-bold text-gray-900 mb-4">{slide.title}</h2>
              {slide.description && (
                <p className="text-lg text-gray-600 max-w-3xl mx-auto">{slide.description}</p>
              )}
              <div className="flex justify-center gap-6 flex-wrap">
                {slide.images.map((img, idx) => (
                  <div key={idx} className="flex flex-col items-center gap-2">
                    <img
                      src={`/assets/${img.src}`}
                      alt={img.caption}
                      className="max-h-[420px] w-auto border border-gray-300 rounded-lg shadow-lg bg-white p-3"
                    />
                    <p className="text-base text-gray-600">{img.caption}</p>
                  </div>
                ))}
              </div>
            </div>
          )}

          {slide.type === 'closing' && (
            <div className="text-center space-y-8">
              <h1 className="text-5xl font-bold text-gray-900 mb-4">{slide.title}</h1>
              <p className="text-3xl text-orange-400 mb-8">{slide.content}</p>
              <div className="space-y-2 text-gray-700">
                {slide.contact.map((line, idx) => (
                  <p key={idx} className="text-xl">{line}</p>
                ))}
              </div>
            </div>
          )}
        </div>
      </div>

      {/* Navigation */}
      <div className="bg-gray-100 border-t border-gray-300 p-4 flex items-center justify-between relative z-20">
        <button
          onClick={prevSlide}
          disabled={currentSlide === 0}
          className="flex items-center gap-2 px-4 py-2 bg-orange-400 text-white rounded-lg disabled:opacity-30 disabled:cursor-not-allowed hover:bg-orange-700 transition"
        >
          <ChevronLeft size={20} />
          Previous
        </button>

        <div className="text-gray-600">
          Slide {currentSlide + 1} of {slides.length}
        </div>

        <button
          onClick={nextSlide}
          disabled={currentSlide === slides.length - 1}
          className="flex items-center gap-2 px-4 py-2 bg-orange-400 text-white rounded-lg disabled:opacity-30 disabled:cursor-not-allowed hover:bg-orange-700 transition"
        >
          Next
          <ChevronRight size={20} />
        </button>
      </div>
    </div>
  );
}

export default App;
