export default {
  options: {
    keepRunning: true,
  },
  defaultBrowser: {
    name: "com.openai.atlas.web",
    appType: "bundleId",
  },
  handlers: [
    {
      match: () => true,
      browser: {
        name: "com.openai.atlas.web",
        appType: "bundleId",
      },
    },
  ],
};
