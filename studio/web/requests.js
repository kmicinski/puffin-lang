// A question a panel puts to the studio and waits on: the message goes out
// with a fresh `seq`, behind any edit still in flight (so the studio
// answers about the text as it is now), and the reply with that `seq`
// resolves the promise. The assists, the rename and the hover's facts each
// keep their own.
//
//   const asks = requests(files);
//   const reply = await asks.ask({ t: "rename", file, pos, name });
//   ...and in the panel's receive: renamed: asks.answer

export function requests(files) {
  const waiting = new Map(); // seq -> resolve
  let seq = 0;
  return {
    ask(message) {
      files.flush();
      const id = ++seq;
      return new Promise((resolve) => {
        waiting.set(id, resolve);
        files.send({ ...message, seq: id });
      });
    },
    answer(reply) {
      waiting.get(reply.seq)?.(reply);
      waiting.delete(reply.seq);
    },
  };
}
