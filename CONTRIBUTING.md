# Contributing to ECR Automation for Air-Gapped Environments

Thank you for your interest in contributing! This document provides guidelines for contributing to this project.

## Code of Conduct

This project adheres to the Amazon Open Source Code of Conduct. By participating, you are expected to uphold this code.

## How to Contribute

### Reporting Bugs

Before creating bug reports, please check existing issues to avoid duplicates. When creating a bug report, include:

- **Clear title and description**
- **Steps to reproduce** the issue
- **Expected behavior** vs actual behavior
- **Environment details** (OS, tool versions, AWS region)
- **Log output** (sanitize any sensitive information)
- **Screenshots** if applicable

### Suggesting Enhancements

Enhancement suggestions are tracked as GitLab issues. When creating an enhancement suggestion, include:

- **Clear title and description**
- **Use case** and motivation
- **Proposed solution** or approach
- **Alternative solutions** considered
- **Impact** on existing functionality

### Merge Requests

1. **Fork the repository** and create your branch from `main`
2. **Make your changes** following the coding standards below
3. **Test your changes** thoroughly
4. **Update documentation** as needed
5. **Commit with clear messages** following Conventional Commits
6. **Submit a merge request** with a clear description

## Development Guidelines

### Bash Scripts

- Use `shellcheck` for linting
- Follow Google Shell Style Guide
- Include comprehensive error handling
- Add comments for complex logic
- Use meaningful variable names
- Test on multiple platforms (Linux, macOS)

### Terraform Code

- Follow HashiCorp style guide
- Use `terraform fmt` for formatting
- Use `terraform validate` for validation
- Include variable descriptions
- Add examples in comments
- Test with `terraform plan`

### Documentation

- Use clear, concise language
- Include code examples
- Add diagrams where helpful
- Keep README.md up to date
- Update CHANGELOG.md for notable changes

## Commit Message Format

Follow Conventional Commits specification:

```
<type>(<scope>): <description>

[optional body]

[optional footer]
```

Types:
- `feat`: New feature
- `fix`: Bug fix
- `docs`: Documentation changes
- `style`: Code style changes (formatting)
- `refactor`: Code refactoring
- `test`: Adding or updating tests
- `chore`: Maintenance tasks

Examples:
```
feat(terraform): add multi-region AWS KMS key support

fix(scripts): handle rate limiting for Docker Hub

docs(readme): update installation instructions
```

## Testing

### Script Testing

```bash
# Lint bash scripts
shellcheck ecr-manager-tool/*.sh

# Test with sample configuration
./ecr-manager-tool/ecr-artifact-manager.sh --config examples/single-chart/charts-config.yaml --region us-east-1
```

### Terraform Testing

```bash
# Format code
terraform fmt -recursive

# Validate configuration
terraform validate

# Plan deployment
terraform plan
```

## Code Review Process

1. All submissions require review
2. Reviewers will check:
   - Code quality and style
   - Test coverage
   - Documentation updates
   - Security implications
   - Performance impact
3. Address review feedback promptly
4. Maintain a respectful, constructive tone

## Security

- **Never commit credentials** or sensitive data
- **Sanitize logs** before sharing
- **Report security issues** privately to AWS Security
- **Follow AWS security best practices**

## Questions?

- Open a GitLab issue for questions
- Tag with `question` label
- Provide context and what you've tried

## License

By contributing, you agree that your contributions will be licensed under the MIT-0 License.

## Thank You!

Your contributions help make this project better for everyone deploying containerized applications in air-gapped environments.
