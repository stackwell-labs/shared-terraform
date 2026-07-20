# Locks in that the trust accepts BOTH the plain OIDC subject and the immutable-ID
# form GitHub emits for transferred repos. A repo that flips to immutable-IDs must keep
# deploying without a trust change. Mocked provider so this needs no AWS credentials.

mock_provider "aws" {}

run "trust_accepts_plain_and_immutable_subject_forms" {
  command = plan

  variables {
    repo        = "stackwell-labs/bowerbird"
    branch      = "main"
    policy_json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
  }

  assert {
    condition = contains(
      output.trust_subject_patterns,
      "repo:stackwell-labs/bowerbird:ref:refs/heads/main",
    )
    error_message = "trust must accept the plain repo:org/name subject form"
  }

  assert {
    condition = contains(
      output.trust_subject_patterns,
      "repo:stackwell-labs@*/bowerbird@*:ref:refs/heads/main",
    )
    error_message = "trust must accept the immutable-ID subject form GitHub emits for transferred repos"
  }
}
