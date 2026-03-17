export default {
  options: {
    keepRunning: true,
  },
  defaultBrowser: {
    name: "company.thebrowser.dia",
    appType: "bundleId",
  },
  handlers: [
    {
      match: () => true,
      browser: {
        name: "company.thebrowser.dia",
        appType: "bundleId",
      },
    },
  ],
};
