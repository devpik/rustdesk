# Guia do Auxiliar de Programação Local (LM Studio)

## 1. Visão Geral
Este guia documenta a integração do auxiliar de programação local rodando no **LM Studio** para apoiar o desenvolvimento do projeto **GigaTech Remoto**.

- **Endpoint da API:** `http://127.0.0.1:1234/v1` (estritamente restrito a `127.0.0.1` / localhost).
- **Modelo Carregado:** `qwen3.5-9b-coder` (9B parâmetros, Qwen 3.5 Coder, 6.41 GB).
- **CLI Local do LM Studio:** `C:\Users\fefem\.lmstudio\bin\lms.exe`
- **Script da Ponte (Bridge):** `C:\Users\fefem\.gemini\antigravity\scratch\lmstudio_assistant.py`
- **Skill Registrada:** `.agents/skills/lmstudio-assistant/SKILL.md`

---

## 2. Divisão de Responsabilidades
- **Auxiliar Local (LM Studio):** Recebe instruções, tarefas isoladas ou trechos de arquivos e devolve propostas de código, scaffolds, regexes e sugestões de refatoração.
- **Agente Principal (Antigravity):** Responsável por arquitetura, validação de regras de negócio, revisão de segurança, aplicação de patches/diffs no repositório, compilação e testes de integração.
- **Isolamento de Segurança:** O modelo na nuvem do Antigravity **não** foi alterado. O servidor local **não** está exposto à internet.

---

## 3. Comandos Úteis

### Iniciar o Servidor Local (se estiver desligado ou após reiniciar o PC)
```powershell
C:\Users\fefem\.lmstudio\bin\lms.exe server start --port 1234 --bind 127.0.0.1
```

### Checar Status da Conexão
```powershell
python C:\Users\fefem\.gemini\antigravity\scratch\lmstudio_assistant.py --status
```

### Consultar Tarefa Simples
```powershell
python C:\Users\fefem\.gemini\antigravity\scratch\lmstudio_assistant.py --prompt "Escreva uma função Rust para..."
```

### Consultar com Arquivo de Contexto
```powershell
python C:\Users\fefem\.gemini\antigravity\scratch\lmstudio_assistant.py --prompt "Identifique possíveis deadlocks" --file "src/rendezvous_mediator.rs"
```

---

## 4. Registro da Validação e Teste Inicial

- **Data do Teste:** 03/11/2026 18:54 (Horário Local)
- **Tarefa Testada:** Geração de função PHP `validate_reset_token` (validação de 64 caracteres hexadecimais e timestamp futuro).
- **Tempo de Execução:** `6.89s` (Prompt: 191 tokens | Completion: 259 tokens | Total: 450 tokens).
- **Resultado do Código:** Sintaxe PHP 7.4+ válida com tipagem estrita e regex correta.
- **Ajuste Realizado pelo Agente Principal:** Padronização da regex para minúsculas (`[a-f0-9]{64}`) conforme especificação do token gerado por `bin2hex()`.
- **Comparação de Desempenho / Produtividade:**
  - *Execução direta pelo modelo Nuvem:* ~1.5s.
  - *Execução pelo Modelo Local (LM Studio):* 6.89s.
  - *Conclusão:* Em tarefas unitárias isoladas, o modelo na nuvem é mais rápido. No entanto, o auxiliar local oferece ganho significativo em **privacidade estrita**, **redução de consumo de cota de tokens na nuvem** e capacidade de **exploração/rascunho de código sem custo**.
